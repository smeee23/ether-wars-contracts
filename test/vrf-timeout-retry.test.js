const { expect } = require("chai");
const { ethers, network } = require("hardhat");

const COMMIT_DURATION = 4 * 60 * 60;
const REVEAL_DURATION = 2 * 60 * 60;
const TIMEOUT = 100;

describe("TournamentManager VRF timeout and retry", function () {
  function revertData(error) {
    const candidates = [
      error && error.data,
      error && error.error && error.error.data,
      error && error.error && error.error.error && error.error.error.data,
    ];
    for (const candidate of candidates) {
      if (typeof candidate === "string" && candidate.startsWith("0x")) {
        return candidate;
      }
      if (
        candidate &&
        typeof candidate.data === "string" &&
        candidate.data.startsWith("0x")
      ) {
        return candidate.data;
      }
    }
    return undefined;
  }

  async function expectCustomError(promise, contract, errorName) {
    try {
      await promise;
      expect.fail(`expected ${errorName}`);
    } catch (error) {
      const data = revertData(error);
      expect(data, error.message).to.not.equal(undefined);
      expect(contract.interface.parseError(data).name).to.equal(errorName);
    }
  }

  async function advance(seconds) {
    await network.provider.send("evm_increaseTime", [seconds]);
    await network.provider.send("evm_mine");
  }

  async function deployGame() {
    const [admin, alice, bob, outsider] = await ethers.getSigners();
    const StETH = await ethers.getContractFactory("StETHMock");
    const Adapter = await ethers.getContractFactory("StETHYieldAdapter");
    const LandLord = await ethers.getContractFactory("LandLord");
    const Tournament = await ethers.getContractFactory("TournamentManager");
    const Battle = await ethers.getContractFactory("BattleManager");
    const Vrf = await ethers.getContractFactory("VRFProviderMock");

    const stETH = await StETH.deploy();
    const adapter = await Adapter.deploy(stETH.address, ethers.constants.AddressZero);
    const implementation = await LandLord.deploy();
    const tournament = await Tournament.deploy(
      adapter.address,
      implementation.address,
      1,
      ethers.utils.parseEther("1")
    );
    await adapter.setController(tournament.address);
    const battle = await Battle.deploy(tournament.address, 1);
    const vrf = await Vrf.deploy(tournament.address);
    await tournament.setBattleManager(battle.address);
    await tournament.setVrfRequestTimeout(TIMEOUT);
    await tournament.setVrfProvider(vrf.address);
    await tournament.connect(alice).registerWithETH({ value: ethers.utils.parseEther("1") });
    await tournament.connect(bob).registerWithETH({ value: ethers.utils.parseEther("1") });
    await tournament.startTournament();
    await tournament.startBattleRound();

    return { admin, alice, bob, outsider, tournament, battle, vrf };
  }

  async function moveToResolve() {
    await advance(COMMIT_DURATION + REVEAL_DURATION + 1);
  }

  async function request(ctx, caller = ctx.outsider) {
    const requestId = await ctx.vrf.nextRequestId();
    const tx = await ctx.tournament.connect(caller).requestRoundRandomness();
    return { requestId, tx, receipt: await tx.wait() };
  }

  function defendPlan(colonyId) {
    return {
      action: {
        actionType: 1,
        target: ethers.constants.AddressZero,
        amount: 0,
        sourceColonyId: 0,
        targetColonyId: 0,
      },
      allocations: [{
        colonyId,
        food: 6,
        water: 6,
        oxygen: 6,
        shelter: 6,
        army: 6,
      }],
      claimExpansion: false,
    };
  }

  async function revealSurvivalPlans(ctx) {
    const entries = [];
    for (const player of [ctx.alice, ctx.bob]) {
      const colonies = await ctx.tournament.getPlayerColonies(player.address);
      const plan = defendPlan(colonies[0].toNumber());
      const salt = ethers.utils.keccak256(
        ethers.utils.toUtf8Bytes(`survive-${player.address}`)
      );
      const hash = await ctx.battle.computePlanCommitHash(
        player.address,
        plan,
        salt,
        1
      );
      await ctx.battle.connect(player).commitPlan(hash);
      entries.push({ player, plan, salt });
    }
    await advance(COMMIT_DURATION + 1);
    for (const entry of entries) {
      await ctx.battle.connect(entry.player).revealPlan(entry.plan, entry.salt);
    }
    await advance(REVEAL_DURATION + 1);
  }

  it("allows any address to create the initial request after Reveal", async function () {
    const ctx = await deployGame();
    await moveToResolve();
    const { requestId, receipt } = await request(ctx, ctx.outsider);
    const block = await ethers.provider.getBlock(receipt.blockNumber);
    const event = receipt.events.find(
      (candidate) => candidate.event === "RoundRandomnessRequested"
    );

    expect(event.args.roundId.toString()).to.equal("1");
    expect(event.args.requestId.toString()).to.equal(requestId.toString());
    expect(event.args.attempt.toString()).to.equal("1");
    expect(event.args.requestedAt.toString()).to.equal(block.timestamp.toString());
  });

  it("rejects requests before Reveal has ended", async function () {
    const ctx = await deployGame();
    await expectCustomError(
      ctx.tournament.connect(ctx.outsider).requestRoundRandomness(),
      ctx.tournament,
      "VrfRevealStillOpen"
    );
    await advance(COMMIT_DURATION + 1);
    await expectCustomError(
      ctx.tournament.connect(ctx.outsider).requestRoundRandomness(),
      ctx.tournament,
      "VrfRevealStillOpen"
    );
  });

  it("rejects a second initial request while one is active", async function () {
    const ctx = await deployGame();
    await moveToResolve();
    await request(ctx);
    await expectCustomError(
      ctx.tournament.requestRoundRandomness(),
      ctx.tournament,
      "VrfRequestAlreadyActive"
    );
  });

  it("rejects retry one second early and permits it at the timeout", async function () {
    const ctx = await deployGame();
    await moveToResolve();
    const first = await request(ctx);
    const requestState = await ctx.tournament.roundVrfState(1);
    const eligibleAt = requestState.requestedAt.add(TIMEOUT).toNumber();

    await network.provider.send("evm_setNextBlockTimestamp", [eligibleAt - 1]);
    await expectCustomError(
      ctx.tournament.connect(ctx.outsider).retryRoundRandomness(),
      ctx.tournament,
      "VrfRequestNotExpired"
    );

    await network.provider.send("evm_setNextBlockTimestamp", [eligibleAt]);
    const newRequestId = await ctx.vrf.nextRequestId();
    const tx = await ctx.tournament.connect(ctx.outsider).retryRoundRandomness();
    const receipt = await tx.wait();
    const retried = receipt.events.find(
      (candidate) => candidate.event === "RoundRandomnessRetried"
    );

    expect(await ctx.tournament.staleVrfRequest(first.requestId)).to.equal(true);
    expect(retried.args.previousRequestId.toString()).to.equal(
      first.requestId.toString()
    );
    expect(retried.args.newRequestId.toString()).to.equal(newRequestId.toString());
    expect(retried.args.attempt.toString()).to.equal("2");
  });

  it("rejects stale callbacks and accepts only the replacement request", async function () {
    const ctx = await deployGame();
    await moveToResolve();
    const first = await request(ctx);
    await advance(TIMEOUT);
    const secondRequestId = await ctx.vrf.nextRequestId();
    await ctx.tournament.retryRoundRandomness();

    await expectCustomError(
      ctx.vrf.fulfill(first.requestId, 111),
      ctx.tournament,
      "StaleVrfRequest"
    );
    await ctx.vrf.fulfill(secondRequestId, 222);
    expect((await ctx.battle.getRoundRandomness(1)).toString()).to.equal("222");
  });

  it("rejects duplicate callbacks and retries after fulfillment", async function () {
    const ctx = await deployGame();
    await moveToResolve();
    const active = await request(ctx);
    await ctx.vrf.fulfill(active.requestId, 123);

    await expectCustomError(
      ctx.vrf.fulfill(active.requestId, 456),
      ctx.tournament,
      "VrfRandomnessAlreadyFulfilled"
    );
    await advance(TIMEOUT);
    await expectCustomError(
      ctx.tournament.retryRoundRandomness(),
      ctx.tournament,
      "VrfRandomnessAlreadyFulfilled"
    );
  });

  it("rejects callbacks for unknown request IDs", async function () {
    const ctx = await deployGame();
    await moveToResolve();
    await expectCustomError(
      ctx.vrf.forceFulfill(999, 123),
      ctx.tournament,
      "UnknownVrfRequest"
    );
  });

  it("prevents a previous round request from affecting a later round", async function () {
    const ctx = await deployGame();
    await revealSurvivalPlans(ctx);
    const first = await request(ctx);
    await ctx.vrf.fulfill(first.requestId, 123);
    await ctx.tournament.resolveTableConflicts(1, 1);
    await ctx.tournament.endBattleRound();
    await ctx.tournament.startBattleRound();

    await expectCustomError(
      ctx.vrf.fulfill(first.requestId, 456),
      ctx.tournament,
      "VrfRequestRoundMismatch"
    );
    expect((await ctx.battle.getRoundRandomness(2)).toString()).to.equal("0");
  });

  it("freezes the VRF provider and timeout once registration starts", async function () {
    const ctx = await deployGame();
    const Replacement = await ethers.getContractFactory("VRFProviderMock");
    const replacement = await Replacement.deploy(ctx.tournament.address);

    await expectCustomError(
      ctx.tournament.setVrfProvider(replacement.address),
      ctx.tournament,
      "VrfConfigurationFrozen"
    );
    await expectCustomError(
      ctx.tournament.setVrfRequestTimeout(1),
      ctx.tournament,
      "VrfConfigurationFrozen"
    );
  });

  it("resolves the round normally after a successful retry", async function () {
    const ctx = await deployGame();
    await moveToResolve();
    await request(ctx);
    await advance(TIMEOUT);
    const activeRequestId = await ctx.vrf.nextRequestId();
    await ctx.tournament.retryRoundRandomness();
    await ctx.vrf.fulfill(activeRequestId, 987);

    await ctx.tournament.resolveTableConflicts(1, 1);
    expect(await ctx.battle.tableConflictsResolved(1, 1)).to.equal(true);
  });
});
