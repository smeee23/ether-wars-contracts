const { expect } = require("chai");
const { ethers, network } = require("hardhat");

const ATTACK = 1;
const DEFEND = 2;
const BUILD = 3;
const BASE_SCORE = 100;
const DEFEND_BONUS = 20;
const ATTACK_VS_DEFEND_PENALTY = 15;
const ARMY_SCORE_DIVISOR = 10;
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
    await ctx.vrfProvider.fulfill(1, randomness);
    return (await ctx.battleManager.currentRound()).toNumber();
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

  async function resolveTable(ctx, roundId, tableId = 1) {
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
    if (action.sourceColonyId === undefined || action.sourceColonyId === 0) {
      action.sourceColonyId = await firstColonyOf(ctx, player);
    }
    if (action.actionType === ATTACK) {
      if (action.targetColonyId === undefined || action.targetColonyId === 0) {
        action.targetColonyId = await firstColonyOf(ctx, action.target);
      }
    } else {
      action.targetColonyId = 0;
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

  it("charges a losing BUILD participant the groupStake", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const seed = attackerWinningSeed(1, 1, a, b, 145, 100);
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
    expect((await aLandLord.getGold()).toString()).to.equal("120");
    expect((await bLandLord.getGold()).toString()).to.equal("80");
  });

  it("stores BUILD support credit without resource gains or decay skips", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const roundId = await startRound(ctx);

    const bAction = build();
    const bSalt = await commitAction(ctx, b, roundId, bAction, "b");

    await revealPhase();
    await revealAction(ctx, b, bAction, bSalt);
    await resolvePhase();
    await ctx.tournament.endBattleRound();

    const aLandLord = await landLordOf(ctx, a);
    const bLandLord = await landLordOf(ctx, b);
    const aResources = await aLandLord.getResources();
    const bResources = await bLandLord.getResources();

    expect(aResources.food.toString()).to.equal("100");
    expect(aResources.water.toString()).to.equal("100");
    expect(aResources.oxygen.toString()).to.equal("100");
    expect(aResources.shelter.toString()).to.equal("100");
    expect(aResources.army.toString()).to.equal("40");
    expect(bResources.food.toString()).to.equal("100");
    expect(bResources.water.toString()).to.equal("100");
    expect(bResources.oxygen.toString()).to.equal("100");
    expect(bResources.shelter.toString()).to.equal("100");
    expect(bResources.army.toString()).to.equal("40");
    expect((await bLandLord.supportCredits()).toString()).to.equal("1");
    expect((await bLandLord.effectiveRoundForSupport(roundId)).toString()).to.equal("0");
  });

  it("expands into an internal colony without changing table seats", async function () {
    const ctx = await deployGame(2);
    const [a] = ctx.players;
    await startRound(ctx);

    const tableBefore = await ctx.tournament.getPlayerTable(a.address);
    await ctx.tournament.connect(a).expand();
    const tableAfter = await ctx.tournament.getPlayerTable(a.address);
    const colonies = await ctx.tournament.getPlayerColonies(a.address);

    expect(tableAfter.toString()).to.equal(tableBefore.toString());
    expect(colonies.length).to.equal(2);
    expect((await ctx.tournament.expansionsUsed(a.address)).toString()).to.equal("1");
    expect((await ctx.tournament.activeColonyCount(a.address)).toString()).to.equal("2");
  });

  it("transfers gold between active colonies only during commit phase", async function () {
    const ctx = await deployGame(2);
    const [a] = ctx.players;
    await startRound(ctx);
    await ctx.tournament.connect(a).expand();

    const colonies = await ctx.tournament.getPlayerColonies(a.address);
    const first = colonies[0].toNumber();
    const second = colonies[1].toNumber();
    await ctx.tournament.connect(a).transferGoldBetweenColonies(first, second, 25);

    const firstLandLord = await landLordOfColony(ctx, first);
    const secondLandLord = await landLordOfColony(ctx, second);
    expect((await firstLandLord.getGold()).toString()).to.equal("75");
    expect((await secondLandLord.getGold()).toString()).to.equal("125");

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
    const seed = attackerWinningSeed(1, 1, a, b, 120, 120);
    const roundId = await startRound(ctx, seed);
    await ctx.tournament.connect(b).expand();

    const bColonies = await ctx.tournament.getPlayerColonies(b.address);
    const attackedColony = bColonies[0].toNumber();
    const bLandLord = await landLordOfColony(ctx, attackedColony);
    await bLandLord.connect(b).spendGoldToReplenish(0, 90);

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
    const roundId = await startRound(ctx, randomness);
    await ctx.tournament.connect(a).expand();

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

    const tx = await ctx.tournament.resolveTableConflicts(1, roundId);
    const receipt = await tx.wait();
    const participants = await participantEvents(ctx, receipt);
    const aEvent = participants.find((event) => event.args.player === a.address);
    const hash = groupHash(roundId, 1, [a, b]);
    const firstLandLord = await landLordOfColony(ctx, first);
    const firstArmy = (await firstLandLord.getResources()).army.toNumber();
    const expectedScore =
      BASE_SCORE +
      roll(randomness, roundId, 1, hash, a) +
      Math.floor(firstArmy / ARMY_SCORE_DIVISOR) +
      10 -
      ATTACK_VS_DEFEND_PENALTY;

    expect(aEvent.args.score.toString()).to.equal(expectedScore.toString());
  });

  it("adds army bonus to participant score", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const aLandLord = await landLordOf(ctx, a);
    await aLandLord.connect(a).spendGoldToReplenish(4, 5);

    const randomness = 12345;
    const roundId = await startRound(ctx, randomness);
    const aAction = attack(b.address, 10);
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await resolvePhase();

    const tx = await ctx.tournament.resolveTableConflicts(1, roundId);
    const receipt = await tx.wait();
    const participants = await participantEvents(ctx, receipt);
    const aEvent = participants.find((event) => event.args.player === a.address);
    const hash = groupHash(roundId, 1, [a, b]);
    const army = (await aLandLord.getResources()).army.toNumber();
    const expectedScore =
      BASE_SCORE +
      roll(randomness, roundId, 1, hash, a) +
      Math.floor(army / ARMY_SCORE_DIVISOR) +
      10 -
      ATTACK_VS_DEFEND_PENALTY;

    expect(aEvent.args.score.toString()).to.equal(expectedScore.toString());
  });

  it("gives DEFEND one flat bonus when attacked by multiple players", async function () {
    const ctx = await deployGame(3);
    const [a, b, c] = ctx.players;
    const randomness = 12345;
    const roundId = await startRound(ctx, randomness);

    const aAction = attack(b.address, 10);
    const cAction = attack(b.address, 15);
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");
    const cSalt = await commitAction(ctx, c, roundId, cAction, "c");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await revealAction(ctx, c, cAction, cSalt);
    await resolvePhase();

    const tx = await ctx.tournament.resolveTableConflicts(1, roundId);
    const receipt = await tx.wait();
    const participants = await participantEvents(ctx, receipt);
    const bEvent = participants.find((event) => event.args.player === b.address);
    const bLandLord = await landLordOf(ctx, b);
    const hash = groupHash(roundId, 1, [a, b, c]);
    const army = (await bLandLord.getResources()).army.toNumber();
    const expectedScore =
      BASE_SCORE +
      roll(randomness, roundId, 1, hash, b) +
      Math.floor(army / ARMY_SCORE_DIVISOR) +
      DEFEND_BONUS;

    expect(bEvent.args.score.toString()).to.equal(expectedScore.toString());
  });

  it("charges a losing DEFEND participant the groupStake", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const seed = attackerWinningSeed(1, 1, a, b, 165, 120);
    const roundId = await startRound(ctx, seed);

    const aAction = attack(b.address, 80);
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await resolvePhase();
    await resolveTable(ctx, roundId);

    const aLandLord = await landLordOf(ctx, a);
    const bLandLord = await landLordOf(ctx, b);
    expect((await aLandLord.getGold()).toString()).to.equal("180");
    expect((await bLandLord.getGold()).toString()).to.equal("20");
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
    await bLandLord.connect(b).spendGoldToReplenish(0, 90);

    const seed = attackerWinningSeed(1, 1, a, b, 120, 120);
    const roundId = await startRound(ctx, seed);

    const aAction = attack(b.address, 35);
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await resolvePhase();

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
    expect((await ctx.tournament.playerInfo(b.address)).active).to.equal(false);
  });

  it("does not charge the winner", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;
    const seed = attackerWinningSeed(1, 1, a, b, 165, 120);
    const roundId = await startRound(ctx, seed);

    const aAction = attack(b.address, 80);
    const aSalt = await commitAction(ctx, a, roundId, aAction, "a");

    await revealPhase();
    await revealAction(ctx, a, aAction, aSalt);
    await resolvePhase();

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

  it("eliminates a losing attacker whose wager reduces gold to zero", async function () {
    const ctx = await deployGame(2);
    const [a, b] = ctx.players;

    const aInfo = await ctx.tournament.playerInfo(a.address);
    const aLandLord = ctx.LandLord.attach(aInfo.landLord);
    await aLandLord.connect(a).spendGoldToReplenish(0, 99);

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
    expect((await aLandLord.getGold()).toString()).to.equal("0");
  });
});
