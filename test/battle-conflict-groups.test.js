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

describe("BattleManager connected conflict groups", function () {
  async function deployGame(playerCount) {
    const signers = await ethers.getSigners();
    const admin = signers[0];
    const players = signers.slice(1, playerCount + 1);

    const NoYieldAdapter = await ethers.getContractFactory("NoYieldAdapter");
    const LandLord = await ethers.getContractFactory("LandLord");
    const TournamentManager = await ethers.getContractFactory("TournamentManager");
    const BattleManager = await ethers.getContractFactory("BattleManager");
    const VRFProviderMock = await ethers.getContractFactory("VRFProviderMock");

    const yieldAdapter = await NoYieldAdapter.deploy();
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
        .register(0, { value: ethers.utils.parseEther("1") });
    }

    await tournament.startTournament();

    return {
      admin,
      players,
      tournament,
      battleManager,
      vrfProvider,
      LandLord,
    };
  }

  async function startRound(ctx, randomness = 12345) {
    await ctx.tournament.startBattleRound();
    ctx.roundRandomness = randomness;
    return (await ctx.battleManager.currentRound()).toNumber();
  }

  async function requestRoundRandomness(ctx, roundId, randomness = ctx.roundRandomness || 12345) {
    const requestId = await ctx.vrfProvider.nextRequestId();
    await ctx.tournament.requestRoundRandomness(roundId);
    await ctx.vrfProvider.fulfill(requestId, randomness);
  }

  async function commitAction(ctx, player, roundId, action, saltLabel) {
    const salt = ethers.utils.formatBytes32String(saltLabel);
    await normalizeAction(ctx, player, action);
    const hash = await ctx.battleManager.computeCommitHash(
      player.address,
      action.actionType,
      action.target,
      action.amount,
      action.sourceColonyId,
      action.targetColonyId,
      salt,
      roundId
    );

    await ctx.battleManager.connect(player).commit(hash);
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
    await ctx.battleManager.connect(player).reveal(action, salt);
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
      const firstAttackerScore = 85 + roll(seed, roundId, tableId, firstHash, a);
      const firstDefenderScore = 120 + roll(seed, roundId, tableId, firstHash, b);
      const secondAttackerScore = 85 + roll(seed, roundId, tableId, secondHash, c);
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
    for (const colony of colonies) {
      for (let resource = 0; resource <= 4; resource++) {
        await ctx.tournament.connect(player).allocateColonyGold(
          colony.toNumber(),
          resource,
          6
        );
      }
    }
  }

  async function fundAllSurvival(ctx) {
    for (const player of ctx.players) {
      if ((await ctx.tournament.playerInfo(player.address)).active) {
        await fundColonySurvival(ctx, player);
      }
    }
  }

  async function activateFirstExpansion(ctx, expandPlayers, nextRoundRandomness = 12345) {
    await fundAllSurvival(ctx);
    const setupRoundId = await startRound(ctx);
    for (const player of expandPlayers) {
      await ctx.tournament.connect(player).expand();
    }
    await finishEmptyRound(ctx, setupRoundId);
    return startRound(ctx, nextRoundRandomness);
  }

  async function preparePlayerForElimination(ctx, player) {
    const colonies = await ctx.tournament.getPlayerColonies(player.address);
    await ctx.tournament.connect(player).allocateColonyGold(
      colonies[0].toNumber(),
      0,
      990
    );
  }

  async function unlockExpansionMilestone(ctx) {
    const [a, b, c, d] = ctx.players;
    await fundColonySurvival(ctx, a);
    await fundColonySurvival(ctx, c);
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
    await revealPhase();
    await resolvePhase();
    await resolveTable(ctx, roundId);
    await ctx.tournament.endBattleRound();
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
      ctx.tournament.requestRoundRandomness(roundId),
      "reveal still open"
    );

    await revealPhase();
    await expectRevert(
      ctx.tournament.requestRoundRandomness(roundId),
      "reveal still open"
    );
  });

  it("does not resolve table conflicts before randomness is fulfilled", async function () {
    const ctx = await deployGame(2);
    const roundId = await startRound(ctx);

    await revealPhase();
    await resolvePhase();

    await expectRevert(
      ctx.tournament.resolveTableConflicts(1, roundId),
      "randomness not ready"
    );
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
    const seed = winnerSeed(2, 1, [a, b, c], [85, 120, 85], 0);
    const roundId = await activateFirstExpansion(ctx, [b], seed);

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
    expect((await firstLandLord.getGold()).toString()).to.equal("870");
    expect((await secondLandLord.getGold()).toString()).to.equal("1000");
  });

  it("breaks equal incoming target-colony wagers by lower colony id", async function () {
    const ctx = await deployGame(3);
    const [a, b, c] = ctx.players;
    const seed = winnerSeed(2, 1, [a, b, c], [85, 120, 85], 0);
    const roundId = await activateFirstExpansion(ctx, [b], seed);

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
    expect((await firstLandLord.getGold()).toString()).to.equal("870");
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

    expect(aResources.gold.toString()).to.equal("970");
    expect(firstResources.gold.toString()).to.equal("970");
    expect(secondResources.food.toString()).to.equal("0");
    expect(secondResources.water.toString()).to.equal("0");
    expect(secondResources.oxygen.toString()).to.equal("0");
    expect(secondResources.shelter.toString()).to.equal("0");
    expect(secondResources.army.toString()).to.equal("0");
    expect((await firstLandLord.supportCredits()).toString()).to.equal("1");
    expect((await secondLandLord.supportCredits()).toString()).to.equal("1");
    expect((await firstLandLord.effectiveRoundForSupport(roundId)).toString()).to.equal("0");
    expect((await secondLandLord.effectiveRoundForSupport(roundId)).toString()).to.equal("0");
  });

  it("scores BUILD army from the attacked colony without storing credit when attacked", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const randomness = 12345;
    const roundId = await activateFirstExpansion(ctx, [b], randomness);

    const bColonies = await ctx.tournament.getPlayerColonies(b.address);
    const buildColony = bColonies[0].toNumber();
    const attackedColony = bColonies[1].toNumber();
    await ctx.tournament.connect(b).allocateColonyGold(attackedColony, 4, 30);

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
    const hash = groupHash(roundId, 1, [a, b]);
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

  it("starts each player with one colony and allows first expansion in round one", async function () {
    const ctx = await deployGame(2);
    const [a] = ctx.players;
    await startRound(ctx);

    const colonies = await ctx.tournament.getPlayerColonies(a.address);
    expect(colonies.length).to.equal(1);
    expect((await ctx.tournament.activeColonyCount(a.address)).toString()).to.equal("1");
    expect((await ctx.tournament.maxUnlockedExpansions()).toString()).to.equal("1");

    await ctx.tournament.connect(a).expand();
    expect((await ctx.tournament.getPlayerColonies(a.address)).length).to.equal(2);
  });

  it("allows first and milestone expansions during commit and keeps them pending until the next round", async function () {
    const ctx = await deployGame(4);
    const { survivors } = await unlockExpansionMilestone(ctx);
    const [a, c] = survivors;

    expect((await ctx.tournament.expansionUnlockRound()).toString()).to.equal("1");
    expect((await ctx.tournament.activePlayerCount()).toString()).to.equal("2");

    const roundId = await startRound(ctx);
    const tableBefore = await ctx.tournament.getPlayerTable(a.address);
    await ctx.tournament.connect(a).expand();
    await ctx.tournament.connect(a).expand();
    const tableAfter = await ctx.tournament.getPlayerTable(a.address);
    const colonies = await ctx.tournament.getPlayerColonies(a.address);
    const pendingColony = colonies[1].toNumber();

    expect(tableAfter.toString()).to.equal(tableBefore.toString());
    expect(colonies.length).to.equal(3);
    expect((await ctx.tournament.expansionsUsed(a.address)).toString()).to.equal("2");
    expect((await ctx.tournament.activeColonyCount(a.address)).toString()).to.equal("3");

    await expectRevert(
      ctx.tournament.connect(a).allocateColonyGold(pendingColony, 4, 1),
      "pending"
    );

    const cAction = attack(a.address, 1);
    cAction.targetColonyId = pendingColony;
    const cSalt = await commitAction(ctx, c, roundId, cAction, "c");

    await revealPhase();
    await expectRevert(
      revealAction(ctx, c, cAction, cSalt),
      "invalid attack"
    );
    await resolvePhase();
    await resolveTable(ctx, roundId);
    await ctx.tournament.endBattleRound();

    const nextRoundId = await startRound(ctx);
    expect(nextRoundId).to.equal(roundId + 1);
    await ctx.tournament.connect(a).allocateColonyGold(pendingColony, 4, 1);
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
    await expectRevert(
      ctx.tournament.connect(a).expand(),
      "expansion locked"
    );
  });

  it("transfers gold between active colonies only during commit phase", async function () {
    const ctx = await deployGame(2);
    const [a] = ctx.players;
    await activateFirstExpansion(ctx, [a]);

    const colonies = await ctx.tournament.getPlayerColonies(a.address);
    const first = colonies[0].toNumber();
    const second = colonies[1].toNumber();
    await ctx.tournament.connect(a).transferGoldBetweenColonies(first, second, 25);

    const firstLandLord = await landLordOfColony(ctx, first);
    const secondLandLord = await landLordOfColony(ctx, second);
    expect((await firstLandLord.getGold()).toString()).to.equal("945");
    expect((await secondLandLord.getGold()).toString()).to.equal("1025");

    await revealPhase();
    let reverted = false;
    try {
      await ctx.tournament.connect(a).transferGoldBetweenColonies(first, second, 1);
    } catch (error) {
      reverted = error.message.includes("not commit phase");
    }
    expect(reverted).to.equal(true);
  });

  it("eliminates only the attacked colony while another colony keeps the player active", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const seed = attackerWinningSeed(2, 1, a, b, 85, 120);
    const roundId = await activateFirstExpansion(ctx, [b], seed);

    const bColonies = await ctx.tournament.getPlayerColonies(b.address);
    const attackedColony = bColonies[0].toNumber();
    await ctx.tournament.connect(b).allocateColonyGold(attackedColony, 0, 960);

    const aAction = attack(b.address, 35);
    aAction.targetColonyId = attackedColony;
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
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
    await ctx.tournament.connect(a).allocateColonyGold(second, 4, 30);

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
    const hash = groupHash(roundId, 1, [a, b]);
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
    await ctx.tournament.connect(a).allocateColonyGold(aColonyId, 4, 5);

    const randomness = 12345;
    const roundId = await startRound(ctx, randomness);
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
    const hash = groupHash(roundId, 1, [a, b]);
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
    await ctx.tournament.connect(b).allocateColonyGold(second, 4, 30);

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
    const hash = groupHash(roundId, 1, [a, b, c]);
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
    await ctx.tournament.connect(b).allocateColonyGold(bColonyId, 0, 990);

    const seed = attackerWinningSeed(1, 1, a, b, 85, 120);
    const roundId = await startRound(ctx, seed);

    const aAction = attack(b.address, 35);
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
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
    await ctx.tournament.connect(a).allocateColonyGold(aColonyId, 0, 999);

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
