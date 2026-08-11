const { expect } = require("chai");
const { ethers, network } = require("hardhat");

const DEFEND = 1;
const BUILD = 2;
const COMMIT_DURATION = 4 * 60 * 60;

describe("BattleManager signed batch reveals", function () {
  async function deployGame(playerCount = 2) {
    const [admin, ...signers] = await ethers.getSigners();
    const players = signers.slice(0, playerCount);
    const registrants = signers.slice(0, Math.max(playerCount, 2));

    const StETH = await ethers.getContractFactory("StETHMock");
    const StETHYieldAdapter = await ethers.getContractFactory("StETHYieldAdapter");
    const LandLord = await ethers.getContractFactory("LandLord");
    const TournamentManager = await ethers.getContractFactory("TournamentManager");
    const BattleManager = await ethers.getContractFactory("BattleManager");
    const VRFProviderMock = await ethers.getContractFactory("VRFProviderMock");

    const stETH = await StETH.deploy();
    const yieldAdapter = await StETHYieldAdapter.deploy(
      stETH.address,
      ethers.constants.AddressZero
    );
    const landLordImplementation = await LandLord.deploy();
    const tournament = await TournamentManager.deploy(
      yieldAdapter.address,
      landLordImplementation.address,
      1,
      ethers.utils.parseEther("1")
    );
    const battleManager = await BattleManager.deploy(tournament.address, 1);
    const vrfProvider = await VRFProviderMock.deploy(tournament.address);

    await yieldAdapter.setController(tournament.address);
    await tournament.setBattleManager(battleManager.address);
    await tournament.setVrfProvider(vrfProvider.address);

    for (const player of registrants) {
      await tournament
        .connect(player)
        .registerWithETH({ value: ethers.utils.parseEther("1") });
    }

    await tournament.startTournament();
    await tournament.startBattleRound();

    return {
      admin,
      players,
      battleManager,
      roundId: await battleManager.currentRound(),
    };
  }

  function plan(actionType = DEFEND) {
    return {
      action: {
        actionType,
        target: ethers.constants.AddressZero,
        amount: 0,
        sourceColonyId: 0,
        targetColonyId: 0,
      },
      allocations: [],
    };
  }

  async function commitAndSign(ctx, player, playerPlan, saltLabel) {
    const salt = ethers.utils.keccak256(ethers.utils.toUtf8Bytes(saltLabel));
    const hash = await ctx.battleManager.computePlanCommitHash(
      player.address,
      playerPlan,
      salt,
      ctx.roundId
    );
    await ctx.battleManager.connect(player).commitPlan(hash);
    const signature = await player.signMessage(ethers.utils.arrayify(hash));

    return { player: player.address, plan: playerPlan, salt, signature };
  }

  async function enterRevealPhase() {
    await network.provider.send("evm_increaseTime", [COMMIT_DURATION + 1]);
    await network.provider.send("evm_mine");
  }

  async function expectRevert(promise, reason) {
    try {
      await promise;
      expect.fail("expected transaction to revert");
    } catch (error) {
      expect(error.message).to.include(reason);
    }
  }

  it("lets an unrelated relayer reveal valid plans for multiple players", async function () {
    const ctx = await deployGame(2);
    const [alice, bob] = ctx.players;
    const aliceReveal = await commitAndSign(ctx, alice, plan(DEFEND), "alice");
    const bobReveal = await commitAndSign(ctx, bob, plan(BUILD), "bob");

    await enterRevealPhase();
    const tx = await ctx.battleManager
      .connect(ctx.admin)
      .batchReveal([aliceReveal, bobReveal]);
    const receipt = await tx.wait();
    const events = await ctx.battleManager.queryFilter(
      ctx.battleManager.filters.Revealed(),
      receipt.blockNumber,
      receipt.blockNumber
    );

    expect(events.map((event) => event.args.user)).to.deep.equal([
      alice.address,
      bob.address,
    ]);
    expect((await ctx.battleManager.revealedRound(alice.address)).toString()).to.equal(
      ctx.roundId.toString()
    );
    expect((await ctx.battleManager.revealedRound(bob.address)).toString()).to.equal(
      ctx.roundId.toString()
    );
    expect(
      (await ctx.battleManager.revealed(bob.address)).actionType.toString()
    ).to.equal(String(BUILD));
  });

  it("rejects a signature made by someone other than the declared player", async function () {
    const ctx = await deployGame(2);
    const [alice, bob] = ctx.players;
    const reveal = await commitAndSign(ctx, alice, plan(), "alice");
    reveal.signature = await bob.signMessage(
      ethers.utils.arrayify(await ctx.battleManager.commits(alice.address))
    );

    await enterRevealPhase();
    await expectRevert(ctx.battleManager.batchReveal([reveal]), "bad sig");
    expect((await ctx.battleManager.revealedRound(alice.address)).toString()).to.equal("0");
  });

  it("rejects a valid player signature when it does not match the committed plan", async function () {
    const ctx = await deployGame(1);
    const [alice] = ctx.players;
    const reveal = await commitAndSign(ctx, alice, plan(DEFEND), "alice");
    const differentPlan = plan(BUILD);
    const differentHash = await ctx.battleManager.computePlanCommitHash(
      alice.address,
      differentPlan,
      reveal.salt,
      ctx.roundId
    );
    reveal.plan = differentPlan;
    reveal.signature = await alice.signMessage(ethers.utils.arrayify(differentHash));

    await enterRevealPhase();
    await expectRevert(ctx.battleManager.batchReveal([reveal]), "invalid reveal");
  });

  it("rolls back earlier reveals when a later item in the batch is invalid", async function () {
    const ctx = await deployGame(2);
    const [alice, bob] = ctx.players;
    const aliceReveal = await commitAndSign(ctx, alice, plan(), "alice");
    const bobReveal = await commitAndSign(ctx, bob, plan(), "bob");
    bobReveal.signature = aliceReveal.signature;

    await enterRevealPhase();
    await expectRevert(
      ctx.battleManager.batchReveal([aliceReveal, bobReveal]),
      "bad sig"
    );
    expect((await ctx.battleManager.revealedRound(alice.address)).toString()).to.equal("0");
    expect((await ctx.battleManager.revealedRound(bob.address)).toString()).to.equal("0");
  });

  it("rejects replaying a signed reveal in the same round", async function () {
    const ctx = await deployGame(1);
    const reveal = await commitAndSign(ctx, ctx.players[0], plan(), "alice");

    await enterRevealPhase();
    await ctx.battleManager.batchReveal([reveal]);
    await expectRevert(ctx.battleManager.batchReveal([reveal]), "already revealed");
  });

  it("rejects a signed batch outside the reveal window", async function () {
    const ctx = await deployGame(1);
    const reveal = await commitAndSign(ctx, ctx.players[0], plan(), "alice");

    await expectRevert(ctx.battleManager.batchReveal([reveal]), "wrong phase");
  });
});
