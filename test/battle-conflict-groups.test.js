const { expect } = require("chai");
const { ethers, network } = require("hardhat");

const ATTACK = 0;
const DEFEND = 1;
const BUILD = 2;
const BASE_SCORE = 100;
const DEFEND_BONUS = 25;
const BUILD_VULNERABILITY_BONUS = 50;
const BASIS_POINTS = 10000;
const ARMY_BONUS_BPS_STEP = 500;
const MAX_ARMY_BONUS = 20;
const COMMIT_DURATION = 4 * 60 * 60;
const REVEAL_DURATION = 2 * 60 * 60;

describe("BattleManager connected conflict groups", function () {
  async function deployGame(playerCount) {
    const signers = await ethers.getSigners();
    const admin = signers[0];
    const players = signers.slice(1, playerCount + 1);

    const StETH = await ethers.getContractFactory("StETHMock");
    const StETHYieldAdapter = await ethers.getContractFactory("StETHYieldAdapter");
    const LandLord = await ethers.getContractFactory("LandLord");
    const TournamentManager = await ethers.getContractFactory("TournamentManager");
    const BattleManager = await ethers.getContractFactory("BattleManager");
    const VRFProviderMock = await ethers.getContractFactory("VRFProviderMock");

    const stETH = await StETH.deploy();
    await stETH.deployed();
    const yieldAdapter = await StETHYieldAdapter.deploy(
      stETH.address,
      ethers.constants.AddressZero
    );
    await yieldAdapter.deployed();

    const landLordImplementation = await LandLord.deploy();
    await landLordImplementation.deployed();
    const tournament = await TournamentManager.deploy(
      yieldAdapter.address,
      landLordImplementation.address,
      1,
      ethers.utils.parseEther("1")
    );
    await tournament.deployed();
    await yieldAdapter.setController(tournament.address);

    const battleManager = await BattleManager.deploy(tournament.address, 1);
    await battleManager.deployed();

    const vrfProvider = await VRFProviderMock.deploy(tournament.address);
    await vrfProvider.deployed();

    await tournament.setBattleManager(battleManager.address);
    await tournament.setVrfProvider(vrfProvider.address);

    for (const player of players) {
      await tournament
        .connect(player)
        .registerWithETH({ value: ethers.utils.parseEther("1") });
    }

    await tournament.startTournament();

    return {
      admin,
      players,
      tournament,
      battleManager,
      vrfProvider,
      LandLord,
      queuedAllocations: new Map(),
      committedPlans: new Map(),
    };
  }

  async function startRound(ctx, randomness = 12345) {
    await ctx.tournament.startBattleRound();
    ctx.roundRandomness = randomness;
    return (await ctx.battleManager.currentRound()).toNumber();
  }

  async function requestRoundRandomness(ctx, roundId, randomness = ctx.roundRandomness || 12345) {
    const requestId = await ctx.vrfProvider.nextRequestId();
    await ctx.tournament.requestRoundRandomness();
    await ctx.vrfProvider.fulfill(requestId, randomness);
  }

  async function commitAction(ctx, player, roundId, action, saltLabel) {
    const salt = ethers.utils.keccak256(ethers.utils.toUtf8Bytes(saltLabel));
    await normalizeAction(ctx, player, action);
    const plan = {
      action: {
        actionType: action.actionType,
        target: action.target,
        amount: action.amount,
        sourceColonyId: action.sourceColonyId,
        targetColonyId: action.targetColonyId,
      },
      allocations: (ctx.queuedAllocations.get(player.address) || []).map((allocation) => ({
        colonyId: allocation.colonyId,
        attack: allocation.attack ?? allocation.army ?? 0,
        defense: allocation.defense ?? allocation.army ?? allocation.oxygen ?? 0,
        mining: allocation.mining ?? allocation.food ?? 0,
        infrastructure: allocation.infrastructure ??
          ((allocation.shelter ?? 0) + (allocation.water ?? 0)),
      })),
    };
    const hash = await ctx.battleManager.computePlanCommitHash(
      player.address,
      plan,
      salt,
      roundId
    );

    await ctx.battleManager.connect(player).commitPlan(hash);
    ctx.committedPlans.set(player.address, plan);
    ctx.queuedAllocations.delete(player.address);
    return salt;
  }

  async function revealPhase() {
    await network.provider.send("evm_increaseTime", [COMMIT_DURATION + 1]);
    await network.provider.send("evm_mine");
  }

  async function resolvePhase() {
    await network.provider.send("evm_increaseTime", [REVEAL_DURATION + 1]);
    await network.provider.send("evm_mine");
  }

  async function revealAction(ctx, player, action, salt) {
    action;
    await ctx.battleManager
      .connect(player)
      .revealPlan(ctx.committedPlans.get(player.address), salt);
  }

  async function expectRevert(promise, reason) {
    try {
      await promise;
      expect(false).to.equal(true);
    } catch (error) {
      expect(error.message).to.include(reason);
    }
  }

  async function resolveTable(ctx, roundId, tableId = 1) {
    if ((await ctx.battleManager.getRoundRandomness(roundId)).eq(0)) {
      await requestRoundRandomness(ctx, roundId);
    }
    const tx = await ctx.tournament.resolveTableConflicts(tableId, roundId);
    const receipt = await tx.wait();
    return ctx.battleManager.queryFilter(
      ctx.battleManager.filters.ConflictGroupResolved(),
      receipt.blockNumber,
      receipt.blockNumber
    );
  }

  async function completeActiveFinalization(ctx, batchSize = 10) {
    while (Number(await ctx.tournament.state()) === 1) {
      const phase = Number(await ctx.tournament.finalizationPhase());
      if (phase === 0) return;
      if (phase === 1) {
        await ctx.tournament.processMiningBatch(Math.min(batchSize, 25));
      } else if (phase === 2) {
        await ctx.tournament.processPopulationBatch(Math.min(batchSize, 25));
      } else if (phase === 3) {
        await ctx.tournament.processAutomaticExpansionBatch(
          Math.min(batchSize, 25)
        );
      } else if (phase === 4) {
        await ctx.tournament.processTableCompactionBatch(
          Math.min(batchSize, 25)
        );
      } else if (phase === 5) {
        await ctx.tournament.processTableConsolidationBatch(
          Math.min(batchSize, 25)
        );
      } else if (phase === 6) {
        await ctx.tournament.processBalanceScanBatch(Math.min(batchSize, 50));
      } else if (phase === 7) {
        await ctx.tournament.applyBalanceMove();
      } else if (phase === 8) {
        await ctx.tournament.finalizeRound();
      }
    }
  }

  async function finalizeBattleRound(ctx, batchSize = 10) {
    await ctx.tournament.endBattleRound();
    await completeActiveFinalization(ctx, batchSize);
  }

  function attack(target, amount) {
    return {
      actionType: ATTACK,
      target,
      amount,
      sourceColonyId: 0,
      targetColonyId: 0,
    };
  }

  async function firstColonyOf(ctx, playerOrAddress) {
    const address =
      typeof playerOrAddress === "string" ? playerOrAddress : playerOrAddress.address;
    const colonies = await ctx.tournament.getPlayerColonies(address);
    return colonies[0].toNumber();
  }

  async function normalizeAction(ctx, player, action) {
    if (
      action.actionType === ATTACK &&
      (action.sourceColonyId === undefined || action.sourceColonyId === 0)
    ) {
      action.sourceColonyId = await firstColonyOf(ctx, player);
    }
    if (action.actionType === ATTACK) {
      if (action.targetColonyId === undefined || action.targetColonyId === 0) {
        action.targetColonyId = await firstColonyOf(ctx, action.target);
      }
    } else {
      action.targetColonyId = 0;
    }
    if (action.actionType === DEFEND || action.actionType === BUILD) {
      action.sourceColonyId = 0;
    }
  }

  function encoded(types, values) {
    return ethers.utils.defaultAbiCoder.encode(types, values);
  }

  function groupHash(roundId, tableId, players) {
    let hash = ethers.utils.keccak256(
      encoded(["uint256", "uint256"], [roundId, tableId])
    );
    for (const player of players) {
      hash = ethers.utils.keccak256(
        encoded(["bytes32", "address"], [hash, player.address])
      );
    }
    return hash;
  }

  async function orderedGroupPlayers(ctx, tableId, group) {
    const table = await ctx.tournament.getTablePlayers(tableId);
    const byAddress = new Map(group.map((player) => [player.address, player]));
    return table
      .map((address) => byAddress.get(address))
      .filter((player) => player !== undefined);
  }

  function scoreList(players, scoresByAddress) {
    return players.map((player) => scoresByAddress[player.address]);
  }

  function indexOfPlayer(players, player) {
    return players.findIndex((candidate) => candidate.address === player.address);
  }

  function roll(randomness, roundId, tableId, hash, player) {
    return ethers.BigNumber.from(
      ethers.utils.keccak256(
        encoded(
          ["uint256", "uint256", "uint256", "bytes32", "address"],
          [randomness, roundId, tableId, hash, player.address]
        )
      )
    )
      .mod(100)
      .toNumber();
  }

  function armyBonus(resources, defense = false) {
    const infrastructure = resources.infrastructure.toNumber();
    let infraBps = Math.min(infrastructure, 100) * 10;
    if (infrastructure > 100) {
      infraBps += (Math.min(infrastructure, 500) - 100) * 5;
    }
    if (infrastructure > 500) infraBps += (infrastructure - 500) * 2;
    infraBps = Math.min(infraBps, 5000);
    const capacity = (defense ? resources.defense : resources.attack).toNumber();
    return Math.min(Math.floor(capacity * (10000 + infraBps) / 10000 / 25), 20);
  }

  function defenderWinningSeed(roundId, tableId, attacker, defender) {
    const hash = groupHash(roundId, tableId, [attacker, defender]);
    for (let seed = 1; seed < 1000; seed++) {
      const attackerScore = 101 + roll(seed, roundId, tableId, hash, attacker);
      const defenderScore = 125 + roll(seed, roundId, tableId, hash, defender);
      if (defenderScore > attackerScore) return seed;
    }
    throw new Error("no defender-winning seed found");
  }

  function attackerWinningSeed(roundId, tableId, attacker, target, attackerBase, targetBase) {
    const hash = groupHash(roundId, tableId, [attacker, target]);
    for (let seed = 1; seed < 1000; seed++) {
      const attackerScore =
        attackerBase + roll(seed, roundId, tableId, hash, attacker);
      const targetScore = targetBase + roll(seed, roundId, tableId, hash, target);
      if (attackerScore > targetScore) return seed;
    }
    throw new Error("no attacker-winning seed found");
  }

  function winnerSeed(roundId, tableId, players, baseScores, winnerIndex) {
    const hash = groupHash(roundId, tableId, players);
    for (let seed = 1; seed < 1000; seed++) {
      const scores = players.map((player, index) => (
        baseScores[index] + roll(seed, roundId, tableId, hash, player)
      ));
      const winnerScore = scores[winnerIndex];
      if (scores.every((score, index) => index === winnerIndex || winnerScore > score)) {
        return seed;
      }
    }
    throw new Error("no winning seed found");
  }

  function dualAttackerWinningSeed(roundId, tableId, a, b, c, d) {
    const firstHash = groupHash(roundId, tableId, [a, b]);
    const secondHash = groupHash(roundId, tableId, [c, d]);
    for (let seed = 1; seed < 1000; seed++) {
      const firstAttackerScore = 117 + roll(seed, roundId, tableId, firstHash, a);
      const firstDefenderScore = 125 + roll(seed, roundId, tableId, firstHash, b);
      const secondAttackerScore = 117 + roll(seed, roundId, tableId, secondHash, c);
      const secondDefenderScore = 125 + roll(seed, roundId, tableId, secondHash, d);
      if (
        firstAttackerScore > firstDefenderScore &&
        secondAttackerScore > secondDefenderScore
      ) {
        return seed;
      }
    }
    throw new Error("no dual attacker-winning seed found");
  }

  async function fundColonySurvival(ctx, player) {
    const colonies = await ctx.tournament.getPlayerColonies(player.address);
    const allocations = ctx.queuedAllocations.get(player.address) || [];
    for (const colony of colonies) {
      allocations.push({
        colonyId: colony.toNumber(),
        attack: 60,
        defense: 60,
        mining: 0,
        infrastructure: 120,
      });
    }
    ctx.queuedAllocations.set(player.address, allocations);
  }

  function queueAllocation(ctx, player, colonyId, values) {
    const allocations = ctx.queuedAllocations.get(player.address) || [];
    allocations.push({
      colonyId,
      attack: values.attack ?? values.army ?? 0,
      defense: values.defense ?? values.army ?? values.oxygen ?? 0,
      mining: values.mining ?? values.food ?? 0,
      infrastructure: values.infrastructure ??
        ((values.shelter ?? 0) + (values.water ?? 0)),
    });
    ctx.queuedAllocations.set(player.address, allocations);
  }

  async function fundAllSurvival(ctx) {
    for (const player of ctx.players) {
      if ((await ctx.tournament.playerInfo(player.address)).active) {
        await fundColonySurvival(ctx, player);
      }
    }
  }

  async function fundMilestoneAttacker(ctx, player) {
    const colonyId = await firstColonyOf(ctx, player);
    ctx.queuedAllocations.set(player.address, [{
      colonyId,
      attack: 400,
      defense: 100,
      mining: 100,
      infrastructure: 100,
    }]);
  }

  async function activateFirstExpansion(ctx, _expandPlayers, nextRoundRandomness = 12345) {
    await fundAllSurvival(ctx);
    const setupRoundId = await startRound(ctx);
    await finishEmptyRound(ctx, setupRoundId);
    return startRound(ctx, nextRoundRandomness);
  }

  async function preparePlayerForElimination(ctx, player) {
    const colonies = await ctx.tournament.getPlayerColonies(player.address);
    ctx.queuedAllocations.set(player.address, [{
      colonyId: colonies[0].toNumber(),
      attack: 0,
      defense: 0,
      mining: 990,
      infrastructure: 0,
    }]);
  }

  async function unlockExpansionMilestone(ctx) {
    const [a, b, c, d] = ctx.players;
    await fundMilestoneAttacker(ctx, a);
    await fundMilestoneAttacker(ctx, c);
    await preparePlayerForElimination(ctx, b);
    await preparePlayerForElimination(ctx, d);

    const seed = dualAttackerWinningSeed(1, 1, a, b, c, d);
    const roundId = await startRound(ctx, seed);
    const bColonies = await ctx.tournament.getPlayerColonies(b.address);
    const dColonies = await ctx.tournament.getPlayerColonies(d.address);

    const aAction = attack(b.address, 20);
    aAction.targetColonyId = bColonies[0].toNumber();
    const cAction = attack(d.address, 20);
    cAction.targetColonyId = dColonies[0].toNumber();
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");
    const cSalt = await commitAction(ctx, c, roundId, cAction, "c");
    const bSalt = await commitAction(ctx, b, roundId, defend(), "b");
    const dSalt = await commitAction(ctx, d, roundId, defend(), "d");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await revealAction(ctx, b, defend(), bSalt);
    await revealAction(ctx, c, cAction, cSalt);
    await revealAction(ctx, d, defend(), dSalt);
    await resolvePhase();
    await resolveTable(ctx, roundId);
    await finalizeBattleRound(ctx);

    return { roundId, survivors: [a, c] };
  }

  async function finishEmptyRound(ctx, roundId) {
    const reveals = [];
    for (const player of ctx.players) {
      const info = await ctx.tournament.playerInfo(player.address);
      if (!info.active) continue;
      if (
        !ctx.queuedAllocations.has(player.address)
      ) continue;
      const salt = await commitAction(
        ctx,
        player,
        roundId,
        defend(),
        `plan-${roundId}-${player.address}`
      );
      reveals.push({ player, salt });
    }
    await revealPhase();
    for (const item of reveals) {
      await revealAction(ctx, item.player, defend(), item.salt);
    }
    await resolvePhase();
    await resolveTable(ctx, roundId);
    await finalizeBattleRound(ctx);
    ctx.queuedAllocations.clear();
  }

  async function finishAllTablesRound(
    ctx,
    randomness = 12345,
    batchSize = 10
  ) {
    const roundId = await startRound(ctx, randomness);
    const reveals = [];

    for (const player of ctx.players) {
      const info = await ctx.tournament.playerInfo(player.address);
      if (!info.active || !ctx.queuedAllocations.has(player.address)) continue;

      const salt = await commitAction(
        ctx,
        player,
        roundId,
        defend(),
        `all-tables-${roundId}-${player.address}`
      );
      reveals.push({ player, salt });
    }

    await revealPhase();
    for (const item of reveals) {
      await revealAction(ctx, item.player, defend(), item.salt);
    }
    await resolvePhase();
    await requestRoundRandomness(ctx, roundId, randomness);

    const requiredTableCount = (
      await ctx.battleManager.roundRequiredTableCount(roundId)
    ).toNumber();
    for (let tableId = 1; tableId <= requiredTableCount; tableId++) {
      await ctx.tournament.resolveTableConflicts(tableId, roundId);
    }
    await finalizeBattleRound(ctx, batchSize);

    return roundId;
  }

  async function landLordOf(ctx, player) {
    const colonyId = await firstColonyOf(ctx, player);
    const colony = await ctx.tournament.colonyInfo(colonyId);
    return ctx.LandLord.attach(colony.landLord);
  }

  async function landLordOfColony(ctx, colonyId) {
    const colony = await ctx.tournament.colonyInfo(colonyId);
    return ctx.LandLord.attach(colony.landLord);
  }

  function build() {
    return {
      actionType: BUILD,
      target: ethers.constants.AddressZero,
      amount: 0,
      sourceColonyId: 0,
      targetColonyId: 0,
    };
  }

  function defend() {
    return {
      actionType: DEFEND,
      target: ethers.constants.AddressZero,
      amount: 0,
      sourceColonyId: 0,
      targetColonyId: 0,
    };
  }

  async function participantEvents(ctx, receipt) {
    return ctx.battleManager.queryFilter(
      ctx.battleManager.filters.ConflictParticipant(),
      receipt.blockNumber,
      receipt.blockNumber
    );
  }

  it("resolves A->B and C->A as one 3-player conflict group", async function () {
    const ctx = await deployGame(3);
    const [a, b, c] = ctx.players;
    const roundId = await startRound(ctx);

    const aAction = attack(b.address, 20);
    const cAction = attack(a.address, 30);
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");
    const cSalt = await commitAction(ctx, c, roundId, cAction, "c");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await revealAction(ctx, c, cAction, cSalt);
    await resolvePhase();

    const groups = await resolveTable(ctx, roundId);
    expect(groups.length).to.equal(1);
    expect(groups[0].args.participantCount.toString()).to.equal("3");
  });

  it("does not request randomness before the reveal window closes", async function () {
    const ctx = await deployGame(2);
    const roundId = await startRound(ctx);

    await expectRevert(
      ctx.tournament.requestRoundRandomness(),
      "VrfRevealStillOpen"
    );

    await revealPhase();
    await expectRevert(
      ctx.tournament.requestRoundRandomness(),
      "VrfRevealStillOpen"
    );
  });

  it("does not resolve table conflicts before randomness is fulfilled", async function () {
    const ctx = await deployGame(2);
    const roundId = await startRound(ctx);

    await revealPhase();
    await resolvePhase();

    await expectRevert(
      ctx.tournament.resolveTableConflicts(1, roundId),
      "randomness not set"
    );
    expect((await ctx.battleManager.resolvedTableCount(roundId)).toString()).to.equal("0");
  });

  it("does not end a round before every active table is resolved", async function () {
    const ctx = await deployGame(10);
    const roundId = await startRound(ctx);

    expect((await ctx.battleManager.roundRequiredTableCount(roundId)).toString()).to.equal("2");

    await revealPhase();
    await resolvePhase();
    await requestRoundRandomness(ctx, roundId);

    await ctx.tournament.resolveTableConflicts(1, roundId);
    expect((await ctx.battleManager.resolvedTableCount(roundId)).toString()).to.equal("1");

    await expectRevert(
      ctx.tournament.endBattleRound(),
      "round not over"
    );
    await expectRevert(
      ctx.tournament.startBattleRound(),
      "round active"
    );
  });

  it("does not double count a table resolved twice", async function () {
    const ctx = await deployGame(10);
    const roundId = await startRound(ctx);

    await revealPhase();
    await resolvePhase();
    await requestRoundRandomness(ctx, roundId);

    await ctx.tournament.resolveTableConflicts(1, roundId);
    await expectRevert(
      ctx.tournament.resolveTableConflicts(1, roundId),
      "table resolved"
    );

    expect((await ctx.battleManager.resolvedTableCount(roundId)).toString()).to.equal("1");
  });

  it("ends a round after all required tables are resolved", async function () {
    const ctx = await deployGame(10);
    const roundId = await startRound(ctx);

    expect(await ctx.battleManager.canEndRound()).to.equal(false);
    await revealPhase();
    await resolvePhase();
    await requestRoundRandomness(ctx, roundId);
    expect(await ctx.battleManager.canEndRound()).to.equal(false);

    await ctx.tournament.resolveTableConflicts(1, roundId);
    expect(await ctx.battleManager.canEndRound()).to.equal(false);
    await ctx.tournament.resolveTableConflicts(2, roundId);
    expect((await ctx.battleManager.resolvedTableCount(roundId)).toString()).to.equal("2");
    expect(await ctx.battleManager.canEndRound()).to.equal(true);

    await finalizeBattleRound(ctx);

    expect((await ctx.tournament.lastEndedRound()).toString()).to.equal(String(roundId));
  });

  it("rejects nonexistent table ids without changing resolution accounting", async function () {
    const ctx = await deployGame(2);
    const roundId = await startRound(ctx);

    await revealPhase();
    await resolvePhase();
    await requestRoundRandomness(ctx, roundId);

    await expectRevert(
      ctx.tournament.resolveTableConflicts(0, roundId),
      "invalid table"
    );
    await expectRevert(
      ctx.tournament.resolveTableConflicts(2, roundId),
      "invalid table"
    );
    expect((await ctx.battleManager.resolvedTableCount(roundId)).toString()).to.equal("0");
    expect(await ctx.battleManager.canEndRound()).to.equal(false);
  });

  it("does not rebalance tables until all required tables are resolved", async function () {
    const ctx = await deployGame(10);
    expect((await ctx.tournament.activeTableCount()).toString()).to.equal("2");
    const roundId = await startRound(ctx);
    expect(
      (await ctx.battleManager.roundRequiredTableCount(roundId)).toString()
    ).to.equal("2");
    const tableOneBefore = await ctx.tournament.getTablePlayers(1);
    const tableTwoBefore = await ctx.tournament.getTablePlayers(2);

    await revealPhase();
    await resolvePhase();
    await requestRoundRandomness(ctx, roundId);
    await ctx.tournament.resolveTableConflicts(1, roundId);

    await expectRevert(
      ctx.tournament.endBattleRound(),
      "round not over"
    );

    expect(await ctx.tournament.getTablePlayers(1)).to.deep.equal(tableOneBefore);
    expect(await ctx.tournament.getTablePlayers(2)).to.deep.equal(tableTwoBefore);

    await ctx.tournament.resolveTableConflicts(2, roundId);
    await finalizeBattleRound(ctx);

    expect((await ctx.tournament.lastEndedRound()).toString()).to.equal(String(roundId));
  });

  it("keeps tables stable once their size difference is at most three", async function () {
    const ctx = await deployGame(11);
    await fundAllSurvival(ctx);
    await finishAllTablesRound(ctx, 111);

    const firstTable = await ctx.tournament.getTablePlayers(1);
    const secondTable = await ctx.tournament.getTablePlayers(2);
    expect(firstTable.length).to.equal(7);
    expect(secondTable.length).to.equal(4);

    await finishAllTablesRound(ctx, 222);

    expect(await ctx.tournament.getTablePlayers(1)).to.deep.equal(firstTable);
    expect(await ctx.tournament.getTablePlayers(2)).to.deep.equal(secondTable);
  });

  it("does not eliminate colonies merely because other resource categories are empty", async function () {
    const ctx = await deployGame(10);
    await fundAllSurvival(ctx);

    for (const player of ctx.players.slice(0, 2)) {
      const colonyId = await firstColonyOf(ctx, player);
      ctx.queuedAllocations.set(player.address, [{
        colonyId,
        food: 900,
        water: 0,
        oxygen: 0,
        shelter: 0,
        army: 0,
      }]);
    }

    const originalSecondTable = await ctx.tournament.getTablePlayers(2);
    await finishAllTablesRound(ctx, 333);

    expect((await ctx.tournament.tableCount()).toString()).to.equal("2");
    expect((await ctx.tournament.activeTableCount()).toString()).to.equal("2");
    expect(await ctx.tournament.getTablePlayers(2)).to.include.members(originalSecondTable);
    expect(
      (await ctx.tournament.getPlayerTable(originalSecondTable[0])).toString()
    ).to.equal("2");
    expect(
      (await ctx.tournament.getPlayerTable(ctx.players[0].address)).toString()
    ).to.equal("1");
  });

  it("produces the same final state for small and large batches", async function () {
    const smallBatch = await deployGame(11);
    const largeBatch = await deployGame(11);
    await fundAllSurvival(smallBatch);
    await fundAllSurvival(largeBatch);

    await finishAllTablesRound(smallBatch, 444, 1);
    await finishAllTablesRound(largeBatch, 444, 10);

    for (let tableId = 1; tableId <= 2; tableId++) {
      expect(await smallBatch.tournament.getTablePlayers(tableId)).to.deep.equal(
        await largeBatch.tournament.getTablePlayers(tableId)
      );
    }
    for (let i = 0; i < smallBatch.players.length; i++) {
      const smallLandLord = await landLordOf(smallBatch, smallBatch.players[i]);
      const largeLandLord = await landLordOf(largeBatch, largeBatch.players[i]);
      const smallResources = await smallLandLord.getResources();
      const largeResources = await largeLandLord.getResources();
      expect(smallResources.map(String)).to.deep.equal(
        largeResources.map(String)
      );
    }
  });

  it("enforces finalization phase order and blocks the next round", async function () {
    const ctx = await deployGame(2);
    await fundAllSurvival(ctx);
    const roundId = await startRound(ctx);
    const reveals = [];
    for (const player of ctx.players) {
      const salt = await commitAction(
        ctx,
        player,
        roundId,
        defend(),
        `phase-order-${player.address}`
      );
      reveals.push({ player, salt });
    }
    await revealPhase();
    for (const item of reveals) {
      await revealAction(ctx, item.player, defend(), item.salt);
    }
    await resolvePhase();
    await resolveTable(ctx, roundId);
    await ctx.tournament.endBattleRound();

    await expectRevert(
      ctx.tournament.processPopulationBatch(1),
      "WrongFinalizationPhase"
    );
    await expectRevert(
      ctx.tournament.processMiningBatch(0),
      "InvalidBatchSize"
    );
    await expectRevert(
      ctx.tournament.startBattleRound(),
      "round active"
    );

    await completeActiveFinalization(ctx, 1);
    expect((await ctx.tournament.lastEndedRound()).toString()).to.equal(
      String(roundId)
    );
  });

  it("processes population insolvency in bounded player batches", async function () {
    const ctx = await deployGame(3);
    const [atThreshold, aboveThreshold] = ctx.players;
    const atThresholdColony = await firstColonyOf(ctx, atThreshold);
    const aboveThresholdColony = await firstColonyOf(ctx, aboveThreshold);
    queueAllocation(ctx, atThreshold, atThresholdColony, { mining: 940 });
    queueAllocation(ctx, aboveThreshold, aboveThresholdColony, { mining: 939 });

    const roundId = await startRound(ctx);
    const reveals = [];
    for (const player of ctx.players) {
      const salt = await commitAction(
        ctx,
        player,
        roundId,
        defend(),
        `population-batch-${player.address}`
      );
      reveals.push({ player, salt });
    }
    await revealPhase();
    for (const item of reveals) {
      await revealAction(ctx, item.player, defend(), item.salt);
    }
    await resolvePhase();
    await resolveTable(ctx, roundId);
    await ctx.tournament.endBattleRound();
    await ctx.tournament.processMiningBatch(25);

    expect((await ctx.tournament.finalizationPhase()).toString()).to.equal("2");
    await ctx.tournament.processPopulationBatch(1);
    expect((await ctx.tournament.finalizationPhase()).toString()).to.equal("2");
    expect((await ctx.tournament.playerInfo(atThreshold.address)).active).to.equal(false);
    expect((await ctx.tournament.playerInfo(aboveThreshold.address)).active).to.equal(true);

    await ctx.tournament.processPopulationBatch(2);
    expect((await ctx.tournament.finalizationPhase()).toString()).to.equal("3");
    expect((await ctx.tournament.activePlayerCount()).toString()).to.equal("2");
  });

  it("does not allow unresolved conflicts to be skipped by starting the next round", async function () {
    const ctx = await deployGame(10);
    const roundId = await startRound(ctx);

    await revealPhase();
    await resolvePhase();
    await requestRoundRandomness(ctx, roundId);
    await ctx.tournament.resolveTableConflicts(1, roundId);

    await expectRevert(
      ctx.tournament.endBattleRound(),
      "round not over"
    );
    await expectRevert(
      ctx.tournament.startBattleRound(),
      "round active"
    );

    expect((await ctx.battleManager.currentRound()).toString()).to.equal(String(roundId));
  });

  it("resolves disconnected attacks as separate table conflict groups", async function () {
    const ctx = await deployGame(4);
    const [a, b, c, d] = ctx.players;
    const roundId = await startRound(ctx);

    const aAction = attack(b.address, 10);
    const cAction = attack(d.address, 15);
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");
    const cSalt = await commitAction(ctx, c, roundId, cAction, "c");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await revealAction(ctx, c, cAction, cSalt);
    await resolvePhase();

    const groups = await resolveTable(ctx, roundId);
    expect(groups.length).to.equal(2);
    expect(groups.map((g) => g.args.participantCount.toString())).to.deep.equal([
      "2",
      "2",
    ]);
  });

  it("keeps multiple attackers against the same defender in one group", async function () {
    const ctx = await deployGame(3);
    const [a, b, c] = ctx.players;
    const roundId = await startRound(ctx);

    const aAction = attack(b.address, 10);
    const cAction = attack(b.address, 5);
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");
    const cSalt = await commitAction(ctx, c, roundId, cAction, "c");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await revealAction(ctx, c, cAction, cSalt);
    await resolvePhase();

    await requestRoundRandomness(ctx, roundId);
    const tx = await ctx.tournament.resolveTableConflicts(1, roundId);
    const receipt = await tx.wait();
    const participants = await ctx.battleManager.queryFilter(
      ctx.battleManager.filters.ConflictParticipant(),
      receipt.blockNumber,
      receipt.blockNumber
    );

    const attackers = participants
      .filter((event) => event.args.actionType === ATTACK)
      .map((event) => event.args.player);
    expect(attackers).to.have.members([a.address, c.address]);
  });

  it("charges a losing non-attacker from the colony targeted by the largest incoming wager", async function () {
    const ctx = await deployGame(3);
    const [a, b, c] = ctx.players;
    const roundId = await activateFirstExpansion(ctx, [b]);
    const orderedPlayers = await orderedGroupPlayers(ctx, 1, [a, b, c]);
    ctx.roundRandomness = winnerSeed(
      roundId,
      1,
      orderedPlayers,
      scoreList(orderedPlayers, {
        [a.address]: 100,
        [b.address]: 125,
        [c.address]: 100,
      }),
      indexOfPlayer(orderedPlayers, a)
    );

    const bColonies = await ctx.tournament.getPlayerColonies(b.address);
    const first = bColonies[0].toNumber();
    const second = bColonies[1].toNumber();

    const aAction = attack(b.address, 100);
    aAction.targetColonyId = first;
    const cAction = attack(b.address, 50);
    cAction.targetColonyId = second;
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");
    const cSalt = await commitAction(ctx, c, roundId, cAction, "c");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await revealAction(ctx, c, cAction, cSalt);
    await resolvePhase();
    await resolveTable(ctx, roundId);

    const firstLandLord = await landLordOfColony(ctx, first);
    const secondLandLord = await landLordOfColony(ctx, second);
    expect((await firstLandLord.getGold()).toString()).to.equal("660");
    expect((await secondLandLord.getGold()).toString()).to.equal("1000");
  });

  it("breaks equal incoming target-colony wagers by lower colony id", async function () {
    const ctx = await deployGame(3);
    const [a, b, c] = ctx.players;
    const roundId = await activateFirstExpansion(ctx, [b]);
    const orderedPlayers = await orderedGroupPlayers(ctx, 1, [a, b, c]);
    ctx.roundRandomness = winnerSeed(
      roundId,
      1,
      orderedPlayers,
      scoreList(orderedPlayers, {
        [a.address]: 100,
        [b.address]: 125,
        [c.address]: 100,
      }),
      indexOfPlayer(orderedPlayers, a)
    );

    const bColonies = await ctx.tournament.getPlayerColonies(b.address);
    const first = bColonies[0].toNumber();
    const second = bColonies[1].toNumber();

    const aAction = attack(b.address, 100);
    aAction.targetColonyId = first;
    const cAction = attack(b.address, 100);
    cAction.targetColonyId = second;
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");
    const cSalt = await commitAction(ctx, c, roundId, cAction, "c");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await revealAction(ctx, c, cAction, cSalt);
    await resolvePhase();
    await resolveTable(ctx, roundId);

    const firstLandLord = await landLordOfColony(ctx, first);
    const secondLandLord = await landLordOfColony(ctx, second);
    expect((await firstLandLord.getGold()).toString()).to.equal("660");
    expect((await secondLandLord.getGold()).toString()).to.equal("1000");
  });

  it("charges a losing BUILD participant the groupStake", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const seed = attackerWinningSeed(1, 1, a, b, 125, 100);
    const roundId = await startRound(ctx, seed);

    const aAction = attack(b.address, 20);
    const bAction = build();
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");
    const bSalt = await commitAction(ctx, b, roundId, bAction, "b");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await revealAction(ctx, b, bAction, bSalt);
    await resolvePhase();
    await resolveTable(ctx, roundId);

    const aLandLord = await landLordOf(ctx, a);
    const bLandLord = await landLordOf(ctx, b);
    expect((await aLandLord.getGold()).toString()).to.equal("1020");
    expect((await bLandLord.getGold()).toString()).to.equal("980");
  });

  it("applies population relief to every eligible colony after uncontested BUILD", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const roundId = await activateFirstExpansion(ctx, [b]);
    const bColonies = await ctx.tournament.getPlayerColonies(b.address);

    const bAction = build();
    const bSalt = await commitAction(ctx, b, roundId, bAction, "b");

    await revealPhase();
    await revealAction(ctx, b, bAction, bSalt);
    const firstLandLord = await landLordOfColony(ctx, bColonies[0].toNumber());
    const secondLandLord = await landLordOfColony(ctx, bColonies[1].toNumber());
    await resolvePhase();
    await resolveTable(ctx, roundId);
    await finalizeBattleRound(ctx);

    const aLandLord = await landLordOf(ctx, a);
    const aColonies = await ctx.tournament.getPlayerColonies(a.address);
    const aExpansionLandLord = await landLordOfColony(ctx, aColonies[1].toNumber());
    const aResources = await aLandLord.getResources();
    const aExpansionResources = await aExpansionLandLord.getResources();
    const firstResources = await firstLandLord.getResources();
    const secondResources = await secondLandLord.getResources();

    expect(aResources.gold.toString()).to.equal("760");
    expect(aExpansionResources.gold.toString()).to.equal("1000");
    expect(firstResources.gold.toString()).to.equal("760");
    expect(secondResources.attack.toString()).to.equal("0");
    expect(secondResources.defense.toString()).to.equal("0");
    expect(secondResources.mining.toString()).to.equal("0");
    expect(secondResources.infrastructure.toString()).to.equal("0");
    expect((await firstLandLord.successfulBuildCount()).toString()).to.equal("1");
    expect((await secondLandLord.successfulBuildCount()).toString()).to.equal("1");
  });

  it("does not grant population relief when BUILD is attacked", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const randomness = 12345;
    const roundId = await activateFirstExpansion(ctx, [b], randomness);

    const bColonies = await ctx.tournament.getPlayerColonies(b.address);
    const buildColony = bColonies[0].toNumber();
    const attackedColony = bColonies[1].toNumber();
    queueAllocation(ctx, b, attackedColony, { army: 30 });

    const aAction = attack(b.address, 10);
    aAction.targetColonyId = attackedColony;
    const bAction = build();
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");
    const bSalt = await commitAction(ctx, b, roundId, bAction, "b");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await revealAction(ctx, b, bAction, bSalt);
    await resolvePhase();

    await requestRoundRandomness(ctx, roundId);
    const tx = await ctx.tournament.resolveTableConflicts(1, roundId);
    const receipt = await tx.wait();
    const participants = await participantEvents(ctx, receipt);
    const aEvent = participants.find((event) => event.args.player === a.address);
    const bEvent = participants.find((event) => event.args.player === b.address);
    const hash = groupHash(roundId, 1, await orderedGroupPlayers(ctx, 1, [a, b]));
    const attackedLandLord = await landLordOfColony(ctx, attackedColony);
    const attackerLandLord = await landLordOf(ctx, a);
    const defensePower = await attackedLandLord.effectiveDefense();
    const attackPower = await attackerLandLord.effectiveAttack();
    const maxPower = attackPower.gt(defensePower) ? attackPower : defensePower;
    const militaryPoints = defensePower.mul(MAX_ARMY_BONUS).div(maxPower);
    const expectedScore =
      BASE_SCORE +
      roll(randomness, roundId, 1, hash, b) +
      militaryPoints.toNumber();
    const expectedAttackerScore =
      BASE_SCORE +
      roll(randomness, roundId, 1, hash, a) +
      attackPower.mul(MAX_ARMY_BONUS).div(maxPower).toNumber() +
      BUILD_VULNERABILITY_BONUS;

    expect((await ctx.battleManager.successfulBuildRound(b.address)).toString())
      .to.equal("0");
    expect((await attackedLandLord.successfulBuildCount()).toString()).to.equal("0");
    expect(aEvent.args.score.toString()).to.equal(expectedAttackerScore.toString());
    expect(bEvent.args.score.toString()).to.equal(expectedScore.toString());
    expect(bEvent.args.sourceColonyId.toString()).to.equal("0");
  });

  it("automatically creates the first expansion during finalization", async function () {
    const ctx = await deployGame(2);
    const [a] = ctx.players;
    await fundAllSurvival(ctx);
    const roundId = await startRound(ctx);

    const colonies = await ctx.tournament.getPlayerColonies(a.address);
    expect(colonies.length).to.equal(1);
    expect((await ctx.tournament.maxUnlockedExpansions()).toString()).to.equal("1");

    await revealPhase();
    await resolvePhase();
    await resolveTable(ctx, roundId);
    expect((await ctx.tournament.getPlayerColonies(a.address)).length).to.equal(1);
    await finalizeBattleRound(ctx);

    expect((await ctx.tournament.getPlayerColonies(a.address)).length).to.equal(2);
    expect((await ctx.tournament.expansionsUsed(a.address)).toString()).to.equal("1");
    const expandedColonies = await ctx.tournament.getPlayerColonies(a.address);
    const expanded = await ctx.tournament.colonyInfo(expandedColonies[1]);
    expect(expanded.createdRound.toString()).to.equal(roundId.toString());
  });

  it("automatically creates the milestone expansion in the following round", async function () {
    const ctx = await deployGame(4);
    const { survivors } = await unlockExpansionMilestone(ctx);
    const [a] = survivors;

    expect((await ctx.tournament.expansionUnlockRound()).toString()).to.equal("1");
    expect((await ctx.tournament.activePlayerCount()).toString()).to.equal("2");

    expect((await ctx.tournament.getPlayerColonies(a.address)).length).to.equal(2);
    expect((await ctx.tournament.expansionsUsed(a.address)).toString()).to.equal("1");

    const roundId = await startRound(ctx);
    await finishEmptyRound(ctx, roundId);
    expect((await ctx.tournament.getPlayerColonies(a.address)).length).to.equal(3);
    expect((await ctx.tournament.expansionsUsed(a.address)).toString()).to.equal("2");
  });

  it("does not expose direct allocation or inter-colony transfer functions", async function () {
    const ctx = await deployGame(2);
    expect(ctx.tournament.allocateColonyGold).to.equal(undefined);
    expect(ctx.tournament.transferGoldBetweenColonies).to.equal(undefined);
    const landLord = await landLordOf(ctx, ctx.players[0]);
    expect(landLord.allocateGold).to.equal(undefined);
    expect(landLord.allocateGoldByController).to.equal(undefined);
    expect(ctx.tournament.setRewardManager).to.equal(undefined);
    expect(ctx.tournament.setMapRegistry).to.equal(undefined);
    expect(ctx.tournament.rewardManager).to.equal(undefined);
    expect(ctx.tournament.mapRegistry).to.equal(undefined);
  });

  it("keeps committed allocations unapplied until table resolution", async function () {
    const ctx = await deployGame(2);
    const [a] = ctx.players;
    const colonyId = await firstColonyOf(ctx, a);
    const landLord = await landLordOfColony(ctx, colonyId);
    const roundId = await startRound(ctx);
    queueAllocation(ctx, a, colonyId, { food: 10, army: 5 });
    const salt = await commitAction(ctx, a, roundId, defend(), "hidden-allocation");

    expect((await landLord.getResources()).mining.toString()).to.equal("0");
    await revealPhase();
    await revealAction(ctx, a, defend(), salt);
    expect((await landLord.getResources()).mining.toString()).to.equal("0");

    await resolvePhase();
    await resolveTable(ctx, roundId);
    const resources = await landLord.getResources();
    expect(resources.gold.toString()).to.equal("980");
    expect(resources.mining.toString()).to.equal("10");
    expect(resources.attack.toString()).to.equal("5");
  });

  it("emits colony resource snapshots after allocation and mining settlement", async function () {
    const ctx = await deployGame(2);
    const [a] = ctx.players;
    const colonyId = await firstColonyOf(ctx, a);
    const roundId = await startRound(ctx);
    queueAllocation(ctx, a, colonyId, {
      attack: 10,
      defense: 20,
      mining: 100,
      infrastructure: 30,
    });
    const salt = await commitAction(ctx, a, roundId, defend(), "resource-events");

    await revealPhase();
    await revealAction(ctx, a, defend(), salt);
    await resolvePhase();
    await requestRoundRandomness(ctx, roundId);
    const allocationTx = await ctx.tournament.resolveTableConflicts(1, roundId);
    const allocationReceipt = await allocationTx.wait();
    const allocationEvents = await ctx.tournament.queryFilter(
      ctx.tournament.filters.ColonyResourcesUpdated(roundId, colonyId, a.address),
      allocationReceipt.blockNumber,
      allocationReceipt.blockNumber
    );

    expect(allocationEvents.length).to.equal(1);
    expect(allocationEvents[0].args.gold.toString()).to.equal("840");
    expect(allocationEvents[0].args.attack.toString()).to.equal("10");
    expect(allocationEvents[0].args.defense.toString()).to.equal("20");
    expect(allocationEvents[0].args.mining.toString()).to.equal("100");
    expect(allocationEvents[0].args.infrastructure.toString()).to.equal("30");

    await ctx.tournament.endBattleRound();
    const miningTx = await ctx.tournament.processMiningBatch(25);
    const miningReceipt = await miningTx.wait();
    const miningEvents = await ctx.tournament.queryFilter(
      ctx.tournament.filters.ColonyResourcesUpdated(roundId, colonyId, a.address),
      miningReceipt.blockNumber,
      miningReceipt.blockNumber
    );

    expect(miningEvents.length).to.equal(1);
    expect(miningEvents[0].args.gold.toString()).to.equal("840");
    expect(miningEvents[0].args.mining.toString()).to.equal("100");
  });

  it("rejects a plan whose allocation and wager exceed isolated colony gold", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const colonyId = await firstColonyOf(ctx, a);
    const roundId = await startRound(ctx);
    queueAllocation(ctx, a, colonyId, { food: 901 });
    const action = attack(b.address, 100);
    const salt = await commitAction(ctx, a, roundId, action, "overspend");

    await revealPhase();
    await expectRevert(revealAction(ctx, a, action, salt), "invalid plan");
  });

  it("rejects duplicate colony allocations in one plan", async function () {
    const ctx = await deployGame(2);
    const [a] = ctx.players;
    const colonyId = await firstColonyOf(ctx, a);
    const roundId = await startRound(ctx);
    queueAllocation(ctx, a, colonyId, { food: 1 });
    queueAllocation(ctx, a, colonyId, { water: 1 });
    const salt = await commitAction(ctx, a, roundId, defend(), "duplicate-colony");

    await revealPhase();
    await expectRevert(revealAction(ctx, a, defend(), salt), "invalid plan");
  });

  it("eliminates only the attacked colony while another colony keeps the player active", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const roundId = await activateFirstExpansion(ctx, [b]);
    const orderedPlayers = await orderedGroupPlayers(ctx, 1, [a, b]);
    ctx.roundRandomness = winnerSeed(
      roundId,
      1,
      orderedPlayers,
      scoreList(orderedPlayers, {
        [a.address]: 100,
        [b.address]: 125,
      }),
      indexOfPlayer(orderedPlayers, a)
    );

    const bColonies = await ctx.tournament.getPlayerColonies(b.address);
    const attackedColony = bColonies[0].toNumber();
    const attackedLandLord = await landLordOfColony(ctx, attackedColony);
    const attackedGold = await attackedLandLord.getGold();
    queueAllocation(ctx, b, attackedColony, {
      food: attackedGold.sub(35).toNumber(),
    });

    const aAction = attack(b.address, 35);
    aAction.targetColonyId = attackedColony;
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");
    const bSalt = await commitAction(ctx, b, roundId, defend(), "b");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await revealAction(ctx, b, defend(), bSalt);
    await resolvePhase();
    await resolveTable(ctx, roundId);

    const attackedInfo = await ctx.tournament.colonyInfo(attackedColony);
    expect(attackedInfo.active).to.equal(false);
    expect((await ctx.tournament.activeColonyCount(b.address)).toString()).to.equal("1");
    expect((await ctx.tournament.playerInfo(b.address)).active).to.equal(true);
  });

  it("scores army from the selected source colony, not the owner's other colonies", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const randomness = 12345;
    const roundId = await activateFirstExpansion(ctx, [a], randomness);

    const aColonies = await ctx.tournament.getPlayerColonies(a.address);
    const first = aColonies[0].toNumber();
    const second = aColonies[1].toNumber();
    queueAllocation(ctx, a, second, { army: 30 });

    const aAction = attack(b.address, 10);
    aAction.sourceColonyId = first;
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await resolvePhase();

    await requestRoundRandomness(ctx, roundId);
    const tx = await ctx.tournament.resolveTableConflicts(1, roundId);
    const receipt = await tx.wait();
    const participants = await participantEvents(ctx, receipt);
    const aEvent = participants.find((event) => event.args.player === a.address);
    const hash = groupHash(roundId, 1, await orderedGroupPlayers(ctx, 1, [a, b]));
    const firstLandLord = await landLordOfColony(ctx, first);
    const firstResources = await firstLandLord.getResources();
    const expectedScore =
      BASE_SCORE +
      roll(randomness, roundId, 1, hash, a) +
      MAX_ARMY_BONUS;

    expect(aEvent.args.score.toString()).to.equal(expectedScore.toString());
  });

  it("adds army bonus to participant score", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const aLandLord = await landLordOf(ctx, a);
    const aColonyId = await firstColonyOf(ctx, a);
    const randomness = 12345;
    const roundId = await startRound(ctx, randomness);
    queueAllocation(ctx, a, aColonyId, { army: 5 });
    const aAction = attack(b.address, 10);
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await resolvePhase();

    await requestRoundRandomness(ctx, roundId);
    const tx = await ctx.tournament.resolveTableConflicts(1, roundId);
    const receipt = await tx.wait();
    const participants = await participantEvents(ctx, receipt);
    const aEvent = participants.find((event) => event.args.player === a.address);
    const hash = groupHash(roundId, 1, await orderedGroupPlayers(ctx, 1, [a, b]));
    const resources = await aLandLord.getResources();
    const expectedScore =
      BASE_SCORE +
      roll(randomness, roundId, 1, hash, a) +
      MAX_ARMY_BONUS;

    expect(aEvent.args.score.toString()).to.equal(expectedScore.toString());
  });

  it("awards military points proportionally to the conflict group's strongest participant", async function () {
    const ctx = await deployGame(3);
    const [a, b, c] = ctx.players;
    const aColonyId = await firstColonyOf(ctx, a);
    const bColonyId = await firstColonyOf(ctx, b);
    const cColonyId = await firstColonyOf(ctx, c);
    queueAllocation(ctx, a, aColonyId, { attack: 200 });
    queueAllocation(ctx, b, bColonyId, { attack: 100 });
    queueAllocation(ctx, c, cColonyId, { defense: 50 });

    const randomness = 54321;
    const roundId = await startRound(ctx, randomness);
    const aAction = attack(c.address, 10);
    const bAction = attack(c.address, 10);
    const aSalt = await commitAction(ctx, a, roundId, aAction, "relative-a");
    const bSalt = await commitAction(ctx, b, roundId, bAction, "relative-b");
    const cSalt = await commitAction(ctx, c, roundId, defend(), "relative-c");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await revealAction(ctx, b, bAction, bSalt);
    await revealAction(ctx, c, defend(), cSalt);
    await resolvePhase();
    await requestRoundRandomness(ctx, roundId);
    const tx = await ctx.tournament.resolveTableConflicts(1, roundId);
    const receipt = await tx.wait();
    const participants = await participantEvents(ctx, receipt);
    const ordered = await orderedGroupPlayers(ctx, 1, [a, b, c]);
    const hash = groupHash(roundId, 1, ordered);

    const expectedMilitaryPoints = new Map([
      [a.address, 20],
      [b.address, 10],
      [c.address, 5],
    ]);
    for (const player of [a, b, c]) {
      const event = participants.find((item) => item.args.player === player.address);
      const actionBonus = player.address === c.address ? DEFEND_BONUS : 0;
      const baseAndRandom =
        BASE_SCORE + roll(randomness, roundId, 1, hash, player) + actionBonus;
      expect(event.args.score.sub(baseAndRandom).toString()).to.equal(
        String(expectedMilitaryPoints.get(player.address))
      );
    }
  });

  it("scores DEFEND army from the colony targeted by the largest incoming wager", async function () {
    const ctx = await deployGame(3);
    const [a, b, c] = ctx.players;
    const randomness = 12345;
    const roundId = await activateFirstExpansion(ctx, [b], randomness);

    const bColonies = await ctx.tournament.getPlayerColonies(b.address);
    const first = bColonies[0].toNumber();
    const second = bColonies[1].toNumber();
    queueAllocation(ctx, b, second, { army: 30 });

    const aAction = attack(b.address, 10);
    aAction.targetColonyId = first;
    const cAction = attack(b.address, 15);
    cAction.targetColonyId = second;
    const bAction = defend();
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");
    const cSalt = await commitAction(ctx, c, roundId, cAction, "c");
    const bSalt = await commitAction(ctx, b, roundId, bAction, "b");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await revealAction(ctx, b, bAction, bSalt);
    await revealAction(ctx, c, cAction, cSalt);
    await resolvePhase();

    await requestRoundRandomness(ctx, roundId);
    const tx = await ctx.tournament.resolveTableConflicts(1, roundId);
    const receipt = await tx.wait();
    const participants = await participantEvents(ctx, receipt);
    const bEvent = participants.find((event) => event.args.player === b.address);
    const bLandLord = await landLordOfColony(ctx, second);
    const aLandLord = await landLordOf(ctx, a);
    const cLandLord = await landLordOf(ctx, c);
    const hash = groupHash(roundId, 1, await orderedGroupPlayers(ctx, 1, [a, b, c]));
    const defensePower = await bLandLord.effectiveDefense();
    const attackPowers = [
      await aLandLord.effectiveAttack(),
      await cLandLord.effectiveAttack(),
    ];
    const maxAttackPower = attackPowers[0].gt(attackPowers[1])
      ? attackPowers[0]
      : attackPowers[1];
    const maxPower = maxAttackPower.gt(defensePower)
      ? maxAttackPower
      : defensePower;
    const militaryPoints = defensePower.mul(MAX_ARMY_BONUS).div(maxPower);
    const expectedScore =
      BASE_SCORE +
      roll(randomness, roundId, 1, hash, b) +
      militaryPoints.toNumber() +
      DEFEND_BONUS;

    expect(bEvent.args.score.toString()).to.equal(expectedScore.toString());
    expect(bEvent.args.sourceColonyId.toString()).to.equal("0");
  });

  it("charges a losing DEFEND participant the groupStake", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const seed = attackerWinningSeed(1, 1, a, b, 100, 125);
    const roundId = await startRound(ctx, seed);

    const aAction = attack(b.address, 80);
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await resolvePhase();
    await requestRoundRandomness(ctx, roundId);
    const tx = await ctx.tournament.resolveTableConflicts(1, roundId);
    const receipt = await tx.wait();

    const aLandLord = await landLordOf(ctx, a);
    const bLandLord = await landLordOf(ctx, b);
    expect((await aLandLord.getGold()).toString()).to.equal("1080");
    expect((await bLandLord.getGold()).toString()).to.equal("920");

    const resourceEvents = await ctx.tournament.queryFilter(
      ctx.tournament.filters.ColonyResourcesUpdated(roundId),
      receipt.blockNumber,
      receipt.blockNumber
    );
    expect(resourceEvents.length).to.equal(2);
    const byPlayer = new Map(
      resourceEvents.map((event) => [event.args.player, event.args])
    );
    expect(byPlayer.get(a.address).gold.toString()).to.equal("1080");
    expect(byPlayer.get(b.address).gold.toString()).to.equal("920");
  });

  it("uses the largest attack wager as groupStake in a three-player group", async function () {
    const ctx = await deployGame(3);
    const [a, b, c] = ctx.players;
    const roundId = await startRound(ctx);

    const aAction = attack(b.address, 20);
    const cAction = attack(a.address, 35);
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");
    const cSalt = await commitAction(ctx, c, roundId, cAction, "c");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await revealAction(ctx, c, cAction, cSalt);
    await resolvePhase();

    await requestRoundRandomness(ctx, roundId);
    const tx = await ctx.tournament.resolveTableConflicts(1, roundId);
    const receipt = await tx.wait();
    const groups = await ctx.battleManager.queryFilter(
      ctx.battleManager.filters.ConflictGroupResolved(),
      receipt.blockNumber,
      receipt.blockNumber
    );
    const settlements = await ctx.tournament.queryFilter(
      ctx.tournament.filters.ConflictGoldSettled(),
      receipt.blockNumber,
      receipt.blockNumber
    );

    expect(groups.length).to.equal(1);
    expect(groups[0].args.groupStake.toString()).to.equal("35");
    expect(settlements.length).to.equal(2);
    for (const event of settlements) {
      expect(event.args.groupStake.toString()).to.equal("35");
      expect(event.args.goldTransferred.toString()).to.equal("35");
      expect(event.args.loserEliminated).to.equal(false);
      expect(event.args.loser).to.not.equal(event.args.winner);
    }
  });

  it("caps payment at remaining gold and eliminates an underfunded loser", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const bLandLord = await landLordOf(ctx, b);
    const bColonyId = await firstColonyOf(ctx, b);
    queueAllocation(ctx, b, bColonyId, { food: 990 });

    const seed = attackerWinningSeed(1, 1, a, b, 100, 125);
    const roundId = await startRound(ctx, seed);

    const aAction = attack(b.address, 35);
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");
    const bSalt = await commitAction(ctx, b, roundId, defend(), "b");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await revealAction(ctx, b, defend(), bSalt);
    await resolvePhase();

    await requestRoundRandomness(ctx, roundId);
    const tx = await ctx.tournament.resolveTableConflicts(1, roundId);
    const receipt = await tx.wait();
    const settlements = await ctx.tournament.queryFilter(
      ctx.tournament.filters.ConflictGoldSettled(),
      receipt.blockNumber,
      receipt.blockNumber
    );

    expect(settlements.length).to.equal(1);
    expect(settlements[0].args.groupStake.toString()).to.equal("35");
    expect(settlements[0].args.goldTransferred.toString()).to.equal("10");
    expect(settlements[0].args.loserEliminated).to.equal(true);
    expect((await bLandLord.getGold()).toString()).to.equal("0");
    expect((await ctx.tournament.activeColonyCount(b.address)).toString()).to.equal("0");
    expect((await ctx.tournament.playerInfo(b.address)).active).to.equal(false);
    expect((await ctx.tournament.activeTableCount()).toString()).to.equal("1");
  });

  it("does not charge the winner", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const seed = attackerWinningSeed(1, 1, a, b, 100, 125);
    const roundId = await startRound(ctx, seed);

    const aAction = attack(b.address, 80);
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await resolvePhase();

    await requestRoundRandomness(ctx, roundId);
    const tx = await ctx.tournament.resolveTableConflicts(1, roundId);
    const receipt = await tx.wait();
    const winnerEvents = await ctx.battleManager.queryFilter(
      ctx.battleManager.filters.ConflictWinner(),
      receipt.blockNumber,
      receipt.blockNumber
    );
    const settlementEvents = await ctx.tournament.queryFilter(
      ctx.tournament.filters.ConflictGoldSettled(),
      receipt.blockNumber,
      receipt.blockNumber
    );

    expect(winnerEvents[0].args.winner).to.equal(a.address);
    expect(settlementEvents.some((event) => event.args.loser === a.address)).to.equal(
      false
    );
  });

  it("ignores components with no attacks", async function () {
    const ctx = await deployGame(2);
    const roundId = await startRound(ctx);

    await revealPhase();
    await resolvePhase();

    const groups = await resolveTable(ctx, roundId);
    expect(groups.length).to.equal(0);
  });

  it("treats an attacked non-revealer as DEFEND", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const roundId = await startRound(ctx);

    const aAction = attack(b.address, 10);
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await resolvePhase();

    await requestRoundRandomness(ctx, roundId);
    const tx = await ctx.tournament.resolveTableConflicts(1, roundId);
    const receipt = await tx.wait();
    const participants = await ctx.battleManager.queryFilter(
      ctx.battleManager.filters.ConflictParticipant(),
      receipt.blockNumber,
      receipt.blockNumber
    );

    const defender = participants.find((event) => event.args.player === b.address);
    expect(defender.args.actionType).to.equal(DEFEND);
  });

  it("eliminates a losing attacker's colony whose wager reduces gold to zero", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;

    const aColonyId = await firstColonyOf(ctx, a);
    const aLandLord = await landLordOfColony(ctx, aColonyId);
    queueAllocation(ctx, a, aColonyId, { food: 999 });

    const seed = defenderWinningSeed(1, 1, a, b);
    const roundId = await startRound(ctx, seed);

    const aAction = attack(b.address, 1);
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await resolvePhase();
    await resolveTable(ctx, roundId);

    const updated = await ctx.tournament.playerInfo(a.address);
    expect(updated.active).to.equal(false);
    expect((await ctx.tournament.activeColonyCount(a.address)).toString()).to.equal("0");
    expect((await aLandLord.getGold()).toString()).to.equal("0");
  });
});
