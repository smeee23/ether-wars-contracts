const { expect } = require("chai");
const { ethers, network } = require("hardhat");

const ATTACK = 0;
const DEFEND = 1;
const BUILD = 2;
const BASE_SCORE = 100;
const DEFEND_BONUS = 20;
const ATTACK_VS_DEFEND_PENALTY = 15;
const BASIS_POINTS = 10000;
const ARMY_BONUS_BPS_STEP = 500;
const MAX_ARMY_BONUS = 20;
const COMMIT_DURATION = 4 * 60 * 60;
const REVEAL_DURATION = 2 * 60 * 60;
const PENALTY_RATIO_SMOOTHING_BPS = 500;
const PENALTY_WEIGHT_NUMERATOR = 100000000;
const PENALTY_DOMAIN = ethers.BigNumber.from(
  ethers.utils.keccak256(ethers.utils.toUtf8Bytes("weighted-resource-penalty"))
);
const PENALTY_SELECTION_DOMAIN = ethers.BigNumber.from(
  ethers.utils.keccak256(
    ethers.utils.toUtf8Bytes("weighted-resource-penalty-selection")
  )
);
const PENALTY_SIZE_DOMAIN = ethers.BigNumber.from(
  ethers.utils.keccak256(ethers.utils.toUtf8Bytes("weighted-resource-penalty-size"))
);

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
      queuedExpansions: new Set(),
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
      allocations: ctx.queuedAllocations.get(player.address) || [],
      claimExpansion: ctx.queuedExpansions.has(player.address),
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
    ctx.queuedExpansions.delete(player.address);
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

  function penaltyRoll(randomness, roundId, tableId, resource, totalWeight) {
    return ethers.BigNumber.from(
      ethers.utils.keccak256(
        encoded(
          ["uint256", "uint256", "uint256", "uint256", "uint256"],
          [randomness, roundId, tableId, resource, PENALTY_DOMAIN]
        )
      )
    )
      .mod(totalWeight)
      .toNumber();
  }

  function penaltyWeight(resourceBalance, totalResources) {
    const ratioBps = Math.floor(resourceBalance * BASIS_POINTS / totalResources);
    return Math.floor(
      PENALTY_WEIGHT_NUMERATOR / (PENALTY_RATIO_SMOOTHING_BPS + ratioBps)
    );
  }

  function selectedPenaltyResource(randomness, roundId) {
    return ethers.BigNumber.from(
      ethers.utils.keccak256(
        encoded(
          ["uint256", "uint256", "uint256"],
          [randomness, roundId, PENALTY_SELECTION_DOMAIN]
        )
      )
    ).mod(4).toNumber();
  }

  function penaltyAmount(randomness, roundId, tableId, resource, colonyId, balance) {
    const penaltyBps = ethers.BigNumber.from(
      ethers.utils.keccak256(
        encoded(
          ["uint256", "uint256", "uint256", "uint256", "uint256", "uint256"],
          [randomness, roundId, tableId, resource, colonyId, PENALTY_SIZE_DOMAIN]
        )
      )
    ).mod(1501).add(500);
    return ethers.BigNumber.from(balance).mul(penaltyBps).add(9999).div(10000);
  }

  function weightedPenaltySeed(roundId, tableId, resource, weights, selectedIndex) {
    const totalWeight = weights.reduce((sum, weight) => sum + weight, 0);
    const lowerBound = weights
      .slice(0, selectedIndex)
      .reduce((sum, weight) => sum + weight, 0);
    const upperBound = lowerBound + weights[selectedIndex];
    for (let seed = 1; seed < 1000; seed++) {
      if (selectedPenaltyResource(seed, roundId) !== resource) continue;
      const roll = penaltyRoll(seed, roundId, tableId, resource, totalWeight);
      if (roll >= lowerBound && roll < upperBound) {
        return seed;
      }
    }
    throw new Error("no penalty seed found");
  }

  function armyBonus(resources) {
    const total = ["gold", "food", "water", "oxygen", "shelter", "army"]
      .map((key) => resources[key].toNumber())
      .reduce((sum, value) => sum + value, 0);
    if (total === 0) return 0;

    const armyShareBps = Math.floor(
      (resources.army.toNumber() * BASIS_POINTS) / total
    );
    return Math.min(
      Math.floor(armyShareBps / ARMY_BONUS_BPS_STEP),
      MAX_ARMY_BONUS
    );
  }

  function defenderWinningSeed(roundId, tableId, attacker, defender) {
    const hash = groupHash(roundId, tableId, [attacker, defender]);
    for (let seed = 1; seed < 1000; seed++) {
      const attackerScore = 86 + roll(seed, roundId, tableId, hash, attacker);
      const defenderScore = 120 + roll(seed, roundId, tableId, hash, defender);
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
      const firstAttackerScore = 103 + roll(seed, roundId, tableId, firstHash, a);
      const firstDefenderScore = 120 + roll(seed, roundId, tableId, firstHash, b);
      const secondAttackerScore = 103 + roll(seed, roundId, tableId, secondHash, c);
      const secondDefenderScore = 120 + roll(seed, roundId, tableId, secondHash, d);
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
        food: 60,
        water: 60,
        oxygen: 60,
        shelter: 60,
        army: 60,
      });
    }
    ctx.queuedAllocations.set(player.address, allocations);
  }

  function queueAllocation(ctx, player, colonyId, values) {
    const allocations = ctx.queuedAllocations.get(player.address) || [];
    allocations.push({
      colonyId,
      food: values.food || 0,
      water: values.water || 0,
      oxygen: values.oxygen || 0,
      shelter: values.shelter || 0,
      army: values.army || 0,
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
      food: 100,
      water: 100,
      oxygen: 100,
      shelter: 100,
      army: 400,
    }]);
  }

  async function activateFirstExpansion(ctx, expandPlayers, nextRoundRandomness = 12345) {
    await fundAllSurvival(ctx);
    const setupRoundId = await startRound(ctx);
    for (const player of expandPlayers) {
      ctx.queuedExpansions.add(player.address);
    }
    await finishEmptyRound(ctx, setupRoundId);
    return startRound(ctx, nextRoundRandomness);
  }

  async function preparePlayerForElimination(ctx, player) {
    const colonies = await ctx.tournament.getPlayerColonies(player.address);
    ctx.queuedAllocations.set(player.address, [{
      colonyId: colonies[0].toNumber(),
      food: 990,
      water: 0,
      oxygen: 0,
      shelter: 0,
      army: 0,
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

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await revealAction(ctx, c, cAction, cSalt);
    await resolvePhase();
    await resolveTable(ctx, roundId);
    await ctx.tournament.endBattleRound();

    return { roundId, survivors: [a, c] };
  }

  async function finishEmptyRound(ctx, roundId) {
    const reveals = [];
    for (const player of ctx.players) {
      const info = await ctx.tournament.playerInfo(player.address);
      if (!info.active) continue;
      if (
        !ctx.queuedAllocations.has(player.address) &&
        !ctx.queuedExpansions.has(player.address)
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
    await ctx.tournament.endBattleRound();
    ctx.queuedAllocations.clear();
    ctx.queuedExpansions.clear();
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

    await ctx.tournament.endBattleRound();

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
    const roundId = await startRound(ctx);
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
    await ctx.tournament.endBattleRound();

    expect((await ctx.tournament.lastEndedRound()).toString()).to.equal(String(roundId));
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
        [a.address]: 85,
        [b.address]: 120,
        [c.address]: 85,
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
    expect((await firstLandLord.getGold()).toString()).to.equal("600");
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
        [a.address]: 85,
        [b.address]: 120,
        [c.address]: 85,
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
    expect((await firstLandLord.getGold()).toString()).to.equal("600");
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
    expect((await bLandLord.supportCredits()).toString()).to.equal("0");
  });

  it("stores uncontested BUILD support credit for every active colony during table resolution", async function () {
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
    expect((await firstLandLord.supportCredits()).toString()).to.equal("0");
    expect((await secondLandLord.supportCredits()).toString()).to.equal("0");

    await resolvePhase();
    await resolveTable(ctx, roundId);
    await ctx.tournament.endBattleRound();

    const aLandLord = await landLordOf(ctx, a);
    const aResources = await aLandLord.getResources();
    const firstResources = await firstLandLord.getResources();
    const secondResources = await secondLandLord.getResources();

    expect(aResources.gold.toString()).to.equal("700");
    expect(firstResources.gold.toString()).to.equal("700");
    expect(secondResources.food.toString()).to.equal("0");
    expect(secondResources.water.toString()).to.equal("0");
    expect(secondResources.oxygen.toString()).to.equal("0");
    expect(secondResources.shelter.toString()).to.equal("0");
    expect(secondResources.army.toString()).to.equal("0");
    expect((await firstLandLord.supportCredits()).toString()).to.equal("1");
    expect((await secondLandLord.supportCredits()).toString()).to.equal("1");
    expect((await firstLandLord.effectiveRoundForSupport(roundId)).toString()).to.equal("1");
    expect((await secondLandLord.effectiveRoundForSupport(roundId)).toString()).to.equal("1");
  });

  it("scores BUILD army from the attacked colony without storing credit when attacked", async function () {
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
    const bEvent = participants.find((event) => event.args.player === b.address);
    const hash = groupHash(roundId, 1, await orderedGroupPlayers(ctx, 1, [a, b]));
    const attackedLandLord = await landLordOfColony(ctx, attackedColony);
    const attackedResources = await attackedLandLord.getResources();
    const expectedScore =
      BASE_SCORE +
      roll(randomness, roundId, 1, hash, b) +
      armyBonus(attackedResources);

    const buildLandLord = await landLordOfColony(ctx, buildColony);
    expect((await buildLandLord.supportCredits()).toString()).to.equal("0");
    expect((await attackedLandLord.supportCredits()).toString()).to.equal("0");
    expect(bEvent.args.score.toString()).to.equal(expectedScore.toString());
    expect(bEvent.args.sourceColonyId.toString()).to.equal("0");
  });

  it("creates a committed expansion only during resolution and activates it next round", async function () {
    const ctx = await deployGame(2);
    const [a] = ctx.players;
    await fundAllSurvival(ctx);
    const roundId = await startRound(ctx);

    const colonies = await ctx.tournament.getPlayerColonies(a.address);
    expect(colonies.length).to.equal(1);
    expect((await ctx.tournament.maxUnlockedExpansions()).toString()).to.equal("1");

    ctx.queuedExpansions.add(a.address);
    const salt = await commitAction(ctx, a, roundId, defend(), "expand-a");
    expect((await ctx.tournament.getPlayerColonies(a.address)).length).to.equal(1);

    await revealPhase();
    await revealAction(ctx, a, defend(), salt);
    expect((await ctx.tournament.getPlayerColonies(a.address)).length).to.equal(1);
    await resolvePhase();
    await resolveTable(ctx, roundId);

    expect((await ctx.tournament.getPlayerColonies(a.address)).length).to.equal(2);
    const expandedColonies = await ctx.tournament.getPlayerColonies(a.address);
    const expanded = await ctx.tournament.colonyInfo(expandedColonies[1]);
    expect(expanded.createdRound.toString()).to.equal(roundId.toString());
  });

  it("allows a milestone expansion only through a committed round plan", async function () {
    const ctx = await deployGame(4);
    const { survivors } = await unlockExpansionMilestone(ctx);
    const [a] = survivors;

    expect((await ctx.tournament.expansionUnlockRound()).toString()).to.equal("1");
    expect((await ctx.tournament.activePlayerCount()).toString()).to.equal("2");

    const roundId = await startRound(ctx);
    ctx.queuedExpansions.add(a.address);
    const salt = await commitAction(ctx, a, roundId, defend(), "milestone-a");

    await revealPhase();
    await revealAction(ctx, a, defend(), salt);
    await resolvePhase();
    await resolveTable(ctx, roundId);
    expect((await ctx.tournament.getPlayerColonies(a.address)).length).to.equal(2);
    expect((await ctx.tournament.expansionsUsed(a.address)).toString()).to.equal("1");
  });

  it("closes the milestone expansion window after three rounds", async function () {
    const ctx = await deployGame(4);
    const { survivors } = await unlockExpansionMilestone(ctx);
    const [a] = survivors;

    for (let expectedRound = 2; expectedRound <= 4; expectedRound++) {
      const roundId = await startRound(ctx);
      expect(roundId).to.equal(expectedRound);
      await finishEmptyRound(ctx, roundId);
    }

    const expiredRoundId = await startRound(ctx);
    expect(expiredRoundId).to.equal(5);
    ctx.queuedExpansions.add(a.address);
    const salt = await commitAction(ctx, a, expiredRoundId, defend(), "expired");
    await revealPhase();
    await expectRevert(revealAction(ctx, a, defend(), salt), "invalid plan");
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

    expect((await landLord.getResources()).food.toString()).to.equal("0");
    await revealPhase();
    await revealAction(ctx, a, defend(), salt);
    expect((await landLord.getResources()).food.toString()).to.equal("0");

    await resolvePhase();
    await resolveTable(ctx, roundId);
    const resources = await landLord.getResources();
    expect(resources.gold.toString()).to.equal("985");
    expect(resources.food.toString()).to.equal("10");
    expect(resources.army.toString()).to.equal("5");
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
        [a.address]: 85,
        [b.address]: 120,
      }),
      indexOfPlayer(orderedPlayers, a)
    );

    const bColonies = await ctx.tournament.getPlayerColonies(b.address);
    const attackedColony = bColonies[0].toNumber();
    queueAllocation(ctx, b, attackedColony, { food: 680 });

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
      armyBonus(firstResources) +
      -ATTACK_VS_DEFEND_PENALTY;

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
      armyBonus(resources) +
      -ATTACK_VS_DEFEND_PENALTY;

    expect(aEvent.args.score.toString()).to.equal(expectedScore.toString());
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
    const hash = groupHash(roundId, 1, await orderedGroupPlayers(ctx, 1, [a, b, c]));
    const resources = await bLandLord.getResources();
    const expectedScore =
      BASE_SCORE +
      roll(randomness, roundId, 1, hash, b) +
      armyBonus(resources) +
      DEFEND_BONUS;

    expect(bEvent.args.score.toString()).to.equal(expectedScore.toString());
    expect(bEvent.args.sourceColonyId.toString()).to.equal("0");
  });

  it("charges a losing DEFEND participant the groupStake", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const seed = attackerWinningSeed(1, 1, a, b, 85, 120);
    const roundId = await startRound(ctx, seed);

    const aAction = attack(b.address, 80);
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await resolvePhase();
    await resolveTable(ctx, roundId);

    const aLandLord = await landLordOf(ctx, a);
    const bLandLord = await landLordOf(ctx, b);
    expect((await aLandLord.getGold()).toString()).to.equal("1080");
    expect((await bLandLord.getGold()).toString()).to.equal("920");
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

    const seed = attackerWinningSeed(1, 1, a, b, 85, 120);
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
  });

  it("does not charge the winner", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const seed = attackerWinningSeed(1, 1, a, b, 85, 120);
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

  it("selects one weighted player per resource and favors the lower resource ratio", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const aColonyId = await firstColonyOf(ctx, a);
    const bColonyId = await firstColonyOf(ctx, b);
    const aLandLord = await landLordOfColony(ctx, aColonyId);
    const bLandLord = await landLordOfColony(ctx, bColonyId);

    queueAllocation(ctx, a, aColonyId, {
      food: 200,
      water: 45,
      oxygen: 45,
      shelter: 45,
      army: 45,
    });
    queueAllocation(ctx, b, bColonyId, {
      food: 60,
      water: 45,
      oxygen: 45,
      shelter: 45,
      army: 45,
    });

    const weights = [penaltyWeight(200, 1000), penaltyWeight(60, 1000)];
    const seed = weightedPenaltySeed(1, 1, 0, weights, 1);
    const roundId = await startRound(ctx, seed);
    const requestIdBefore = await ctx.vrfProvider.nextRequestId();
    const aSalt = await commitAction(ctx, a, roundId, defend(), "penalty-a");
    const bSalt = await commitAction(ctx, b, roundId, defend(), "penalty-b");

    await revealPhase();
    await revealAction(ctx, a, defend(), aSalt);
    await revealAction(ctx, b, defend(), bSalt);
    await resolvePhase();
    await resolveTable(ctx, roundId);
    await ctx.tournament.endBattleRound();

    const requestIdAfter = await ctx.vrfProvider.nextRequestId();
    const aEvents = await aLandLord.queryFilter(
      aLandLord.filters.ResourcePenaltyApplied(roundId, a.address, aColonyId)
    );
    const bEvents = await bLandLord.queryFilter(
      bLandLord.filters.ResourcePenaltyApplied(roundId, b.address, bColonyId)
    );
    const foodPenalties = [...aEvents, ...bEvents].filter(
      (event) => Number(event.args.resource) === 0
    );

    expect(requestIdAfter.sub(requestIdBefore).toString()).to.equal("1");
    expect(foodPenalties.length).to.equal(1);
    expect(foodPenalties[0].args.player).to.equal(b.address);
    const expectedPenalty = penaltyAmount(seed, 1, 1, 0, bColonyId, 60);
    expect(foodPenalties[0].args.requested.toString()).to.equal(
      expectedPenalty.toString()
    );
    expect(expectedPenalty.toNumber()).to.be.within(3, 12);
    expect((await aLandLord.getResources()).food.toString()).to.equal("200");
    expect((await bLandLord.getResources()).food.toString()).to.equal(
      ethers.BigNumber.from(60).sub(expectedPenalty).toString()
    );
  });

  it("penalizes the same VRF-selected survival resource at each active table", async function () {
    const ctx = await deployGame(10);
    await fundAllSurvival(ctx);
    const tableOne = new Set(await ctx.tournament.getTablePlayers(1));
    const tableTwo = new Set(await ctx.tournament.getTablePlayers(2));
    const roundId = await startRound(ctx, 777);
    const reveals = [];

    for (const player of ctx.players) {
      const salt = await commitAction(
        ctx,
        player,
        roundId,
        defend(),
        `table-penalty-${player.address}`
      );
      reveals.push({ player, salt });
    }
    await revealPhase();
    for (const item of reveals) {
      await revealAction(ctx, item.player, defend(), item.salt);
    }
    await resolvePhase();
    await requestRoundRandomness(ctx, roundId);
    await ctx.tournament.resolveTableConflicts(1, roundId);
    await ctx.tournament.resolveTableConflicts(2, roundId);
    await ctx.tournament.endBattleRound();

    const resourcePenalties = [];
    for (const player of ctx.players) {
      const colonyId = await firstColonyOf(ctx, player);
      const landLord = await landLordOfColony(ctx, colonyId);
      const events = await landLord.queryFilter(
        landLord.filters.ResourcePenaltyApplied(roundId, player.address, colonyId)
      );
      resourcePenalties.push(...events);
    }

    const selectedResource = selectedPenaltyResource(777, roundId);
    expect(selectedResource).to.be.within(0, 3);
    expect(resourcePenalties.length).to.equal(2);
    expect(
      resourcePenalties.every(
        (event) => Number(event.args.resource) === selectedResource
      )
    ).to.equal(true);
    expect(
      resourcePenalties.filter((event) => tableOne.has(event.args.player)).length
    ).to.equal(1);
    expect(
      resourcePenalties.filter((event) => tableTwo.has(event.args.player)).length
    ).to.equal(1);
  });

  it("applies a selected player's penalty to their weakest eligible colony", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const roundId = await activateFirstExpansion(ctx, [a]);
    const aColonies = await ctx.tournament.getPlayerColonies(a.address);
    const originalColonyId = aColonies[0].toNumber();
    const expandedColonyId = aColonies[1].toNumber();
    const originalLandLord = await landLordOfColony(ctx, originalColonyId);
    const expandedLandLord = await landLordOfColony(ctx, expandedColonyId);
    const bColonyId = await firstColonyOf(ctx, b);
    const bLandLord = await landLordOfColony(ctx, bColonyId);
    const original = await originalLandLord.getResources();
    const bResources = await bLandLord.getResources();
    const supportRequirement = 45;
    const originalFoodTopUp = Math.max(
      0,
      supportRequirement - original.food.toNumber()
    );
    const bFoodTopUp = Math.max(
      0,
      supportRequirement - bResources.food.toNumber()
    );

    queueAllocation(ctx, a, originalColonyId, {
      food: 40 + originalFoodTopUp,
      water: Math.max(0, supportRequirement - original.water.toNumber()),
      oxygen: Math.max(0, supportRequirement - original.oxygen.toNumber()),
      shelter: Math.max(0, supportRequirement - original.shelter.toNumber()),
      army: Math.max(0, supportRequirement - original.army.toNumber()),
    });
    queueAllocation(ctx, a, expandedColonyId, {
      food: supportRequirement,
      water: supportRequirement,
      oxygen: supportRequirement,
      shelter: supportRequirement,
      army: supportRequirement,
    });
    queueAllocation(ctx, b, bColonyId, {
      food: bFoodTopUp,
      water: Math.max(0, supportRequirement - bResources.water.toNumber()),
      oxygen: Math.max(0, supportRequirement - bResources.oxygen.toNumber()),
      shelter: Math.max(0, supportRequirement - bResources.shelter.toNumber()),
      army: Math.max(0, supportRequirement - bResources.army.toNumber()),
    });

    const aFood =
      original.food.toNumber() + 40 + originalFoodTopUp + supportRequirement;
    const bFood = bResources.food.toNumber() + bFoodTopUp;
    ctx.roundRandomness = weightedPenaltySeed(
      roundId,
      1,
      0,
      [penaltyWeight(aFood, 2000), penaltyWeight(bFood, 1000)],
      0
    );

    const aSalt = await commitAction(ctx, a, roundId, defend(), "weakest-a");
    const bSalt = await commitAction(ctx, b, roundId, defend(), "weakest-b");
    await revealPhase();
    await revealAction(ctx, a, defend(), aSalt);
    await revealAction(ctx, b, defend(), bSalt);
    await resolvePhase();
    await resolveTable(ctx, roundId);
    await ctx.tournament.endBattleRound();

    const expandedPenalty = penaltyAmount(
      ctx.roundRandomness,
      roundId,
      1,
      0,
      expandedColonyId,
      supportRequirement
    );
    expect((await expandedLandLord.getResources()).food.toString()).to.equal(
      ethers.BigNumber.from(supportRequirement).sub(expandedPenalty).toString()
    );
    expect((await originalLandLord.getResources()).food.toNumber()).to.be.greaterThan(
      supportRequirement
    );
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
