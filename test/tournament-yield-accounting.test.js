const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("TournamentManager ETH and yield accounting", function () {
  it("preserves principal and adapter share accounting with oxygen resources", async function () {
    const [admin, alice, bob] = await ethers.getSigners();
    const entryDeposit = ethers.utils.parseEther("1");

    const NoYieldAdapter = await ethers.getContractFactory("NoYieldAdapter");
    const LandLord = await ethers.getContractFactory("LandLord");
    const TournamentManager = await ethers.getContractFactory("TournamentManager");

    const yieldAdapter = await NoYieldAdapter.deploy();
    await yieldAdapter.deployed();

    const landLordImplementation = await LandLord.deploy();
    await landLordImplementation.deployed();

    const tournament = await TournamentManager.deploy(
      yieldAdapter.address,
      landLordImplementation.address,
      1,
      entryDeposit
    );
    await tournament.deployed();
    await yieldAdapter.setController(tournament.address);

    await tournament.connect(alice).register(0, { value: entryDeposit });
    await tournament.connect(bob).register(0, { value: entryDeposit });

    expect((await tournament.totalPrincipal()).toString()).to.equal(
      entryDeposit.mul(2).toString()
    );
    expect((await tournament.totalAdapterShares()).toString()).to.equal(
      entryDeposit.mul(2).toString()
    );
    expect((await ethers.provider.getBalance(yieldAdapter.address)).toString()).to.equal(
      entryDeposit.mul(2).toString()
    );

    const aliceInfo = await tournament.playerInfo(alice.address);
    const aliceColonies = await tournament.getPlayerColonies(alice.address);
    const aliceColony = await tournament.colonyInfo(aliceColonies[0]);
    const aliceLandLord = LandLord.attach(aliceColony.landLord);
    const aliceResources = await aliceLandLord.getResources();

    expect(aliceInfo.deposited.toString()).to.equal(entryDeposit.toString());
    expect(aliceInfo.adapterShares.toString()).to.equal(entryDeposit.toString());
    expect(aliceColonies.length).to.equal(1);
    expect(aliceResources.oxygen.toString()).to.equal("0");

    await tournament.startTournament();
    await tournament.connect(admin).completeTournament();
    await tournament.connect(admin).settleTournament();

    await tournament.connect(alice).claimPrincipal();
    await tournament.connect(bob).claimPrincipal();

    expect((await ethers.provider.getBalance(yieldAdapter.address)).toString()).to.equal("0");
  });
});
