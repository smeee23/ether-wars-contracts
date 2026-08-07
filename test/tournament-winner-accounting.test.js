const { expect } = require("chai");
const { ethers, network } = require("hardhat");

describe("TournamentManager winner and principal accounting", function () {
  async function expectRevert(promise, reason) {
    try {
      await promise;
      expect.fail("expected transaction to revert");
    } catch (error) {
      expect(error.message).to.include(reason);
    }
  }

  async function deployTournament() {
    const [admin, alice, bob, caller] = await ethers.getSigners();
    const entryDeposit = ethers.utils.parseEther("1");

    const StETH = await ethers.getContractFactory("StETHMock");
    const StETHYieldAdapter = await ethers.getContractFactory("StETHYieldAdapter");
    const LandLord = await ethers.getContractFactory("LandLord");
    const TournamentManager = await ethers.getContractFactory("TournamentManager");
    const BattleManager = await ethers.getContractFactory("BattleManager");

    const stETH = await StETH.deploy();
    await stETH.deployed();
    const adapter = await StETHYieldAdapter.deploy(
      stETH.address,
      ethers.constants.AddressZero
    );
    await adapter.deployed();
    const implementation = await LandLord.deploy();
    await implementation.deployed();
    const tournament = await TournamentManager.deploy(
      adapter.address,
      implementation.address,
      1,
      entryDeposit
    );
    await tournament.deployed();
    await adapter.setController(tournament.address);
    const battleManager = await BattleManager.deploy(tournament.address, 1);
    await battleManager.deployed();
    await tournament.setBattleManager(battleManager.address);

    await tournament.connect(alice).registerWithETH({ value: entryDeposit });
    await tournament.connect(bob).registerWithETH({ value: entryDeposit });
    await tournament.startTournament();

    await network.provider.send("hardhat_setBalance", [
      battleManager.address,
      "0x56BC75E2D63100000",
    ]);
    await network.provider.send("hardhat_impersonateAccount", [battleManager.address]);
    const battleManagerSigner = await ethers.getSigner(battleManager.address);

    return {
      admin,
      alice,
      bob,
      caller,
      adapter,
      stETH,
      tournament,
      entryDeposit,
      battleManagerSigner,
    };
  }

  it("lets an eliminated player reclaim principal before tournament completion", async function () {
    const { alice, bob, adapter, tournament, entryDeposit, battleManagerSigner } =
      await deployTournament();

    await expectRevert(
      tournament.connect(alice).claimPrincipal(),
      "principal locked"
    );
    await tournament.connect(battleManagerSigner).eliminatePlayer(bob.address);
    await tournament.connect(bob).claimPrincipal();

    expect((await tournament.totalPrincipalStETHClaimed()).toString()).to.equal(
      entryDeposit.toString()
    );
    expect((await adapter.totalAssets()).toString()).to.equal(
      entryDeposit.toString()
    );
    expect((await tournament.state()).toString()).to.equal("1");
  });

  it("finalizes the last active player and lets only that player claim all yield", async function () {
    const {
      admin,
      alice,
      bob,
      adapter,
      stETH,
      tournament,
      entryDeposit,
      battleManagerSigner,
    } =
      await deployTournament();
    const profit = ethers.utils.parseEther("0.25");

    await tournament.connect(battleManagerSigner).eliminatePlayer(bob.address);
    await tournament.connect(bob).claimPrincipal();
    await stETH.mint(adapter.address, profit);
    const completion = await tournament.completeTournament();
    const receipt = await completion.wait();
    const winnerEvents = await tournament.queryFilter(
      tournament.filters.WinnerFinalized(),
      receipt.blockNumber,
      receipt.blockNumber
    );

    expect(await tournament.winner()).to.equal(alice.address);
    expect(winnerEvents.length).to.equal(1);
    expect(winnerEvents[0].args.winner).to.equal(alice.address);
    expect((await tournament.outstandingPrincipalStETH()).toString()).to.equal(
      entryDeposit.toString()
    );
    expect((await tournament.getAvailableYield()).toString()).to.equal(
      profit.toString()
    );

    await expectRevert(tournament.connect(bob).claimYield(), "not winner");
    await tournament.connect(alice).claimYield();
    const secondProfit = ethers.utils.parseEther("0.1");
    await stETH.mint(adapter.address, secondProfit);
    await tournament.connect(alice).claimYield();
    await tournament.connect(alice).claimPrincipal();

    expect((await tournament.totalYieldStETHClaimed()).toString()).to.equal(
      profit.add(secondProfit).toString()
    );
    expect((await stETH.balanceOf(adapter.address)).toString()).to.equal("0");
  });

  it("emergency completion unlocks principal without fabricating a winner", async function () {
    const { alice, bob, adapter, stETH, tournament } = await deployTournament();
    const emergencySurplus = ethers.utils.parseEther("0.2");

    await tournament.completeTournament();
    expect(await tournament.winner()).to.equal(ethers.constants.AddressZero);
    await stETH.mint(adapter.address, emergencySurplus);

    await tournament.connect(alice).claimPrincipal();
    await tournament.connect(bob).claimPrincipal();
    await expectRevert(
      tournament.connect(alice).claimYield(),
      "winner not finalized"
    );
    expect((await stETH.balanceOf(adapter.address)).toString()).to.equal(
      emergencySurplus.toString()
    );
  });

  it("preserves equal principal coverage across claim order after a negative rebase", async function () {
    const { alice, bob, adapter, stETH, tournament, entryDeposit } =
      await deployTournament();
    const loss = ethers.utils.parseEther("0.4");
    const expectedClaim = ethers.utils.parseEther("0.8");

    await tournament.completeTournament();
    await stETH.burn(adapter.address, loss);

    await tournament.connect(alice).claimPrincipal();
    await tournament.connect(bob).claimPrincipal();

    expect((await stETH.balanceOf(alice.address)).toString()).to.equal(
      expectedClaim.toString()
    );
    expect((await stETH.balanceOf(bob.address)).toString()).to.equal(
      expectedClaim.toString()
    );
    expect((await tournament.totalPrincipalStETH()).toString()).to.equal(
      entryDeposit.mul(2).toString()
    );
    expect((await tournament.outstandingPrincipalStETH()).toString()).to.equal("0");
  });
});
