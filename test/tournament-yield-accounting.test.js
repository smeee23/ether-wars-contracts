const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("TournamentManager stETH principal accounting", function () {
  it("accepts ETH and stETH while recording fixed nominal stETH principal", async function () {
    const [admin, alice, bob] = await ethers.getSigners();
    const entryDeposit = ethers.utils.parseEther("1");

    const StETH = await ethers.getContractFactory("StETHMock");
    const Adapter = await ethers.getContractFactory("StETHYieldAdapter");
    const LandLord = await ethers.getContractFactory("LandLord");
    const ResourceLottery = await ethers.getContractFactory("ResourceLottery");
    const Tournament = await ethers.getContractFactory("TournamentManager");

    const stETH = await StETH.deploy();
    const adapter = await Adapter.deploy(
      stETH.address,
      ethers.constants.AddressZero
    );
    const implementation = await LandLord.deploy();
    const resourceLottery = await ResourceLottery.deploy();
    const tournament = await Tournament.deploy(
      adapter.address,
      implementation.address,
      resourceLottery.address,
      1,
      entryDeposit
    );
    await adapter.setController(tournament.address);

    await tournament.connect(alice).registerWithETH({ value: entryDeposit });
    await stETH.mint(bob.address, entryDeposit);
    await stETH.connect(bob).approve(adapter.address, entryDeposit);
    await tournament.connect(bob).registerWithStETH(entryDeposit);

    expect((await tournament.totalPrincipalStETH()).toString()).to.equal(
      entryDeposit.mul(2).toString()
    );
    expect((await tournament.outstandingPrincipalStETH()).toString()).to.equal(
      entryDeposit.mul(2).toString()
    );
    expect((await stETH.balanceOf(adapter.address)).toString()).to.equal(
      entryDeposit.mul(2).toString()
    );

    const aliceInfo = await tournament.playerInfo(alice.address);
    const bobInfo = await tournament.playerInfo(bob.address);
    expect(aliceInfo.principalStETH.toString()).to.equal(entryDeposit.toString());
    expect(bobInfo.principalStETH.toString()).to.equal(entryDeposit.toString());

    await tournament.startTournament();
    await tournament.connect(admin).completeTournament();
    await tournament.connect(alice).claimPrincipal();
    await tournament.connect(bob).claimPrincipal();

    expect((await stETH.balanceOf(alice.address)).toString()).to.equal(
      entryDeposit.toString()
    );
    expect((await stETH.balanceOf(bob.address)).toString()).to.equal(
      entryDeposit.toString()
    );
    expect((await stETH.balanceOf(adapter.address)).toString()).to.equal("0");
  });
});
