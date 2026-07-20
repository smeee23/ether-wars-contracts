const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("ResourceLottery", function () {
  async function deployLotteryAndTournament() {
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
    const lottery = await ResourceLottery.deploy();
    const tournament = await Tournament.deploy(
      adapter.address,
      implementation.address,
      lottery.address,
      1,
      ethers.utils.parseEther("1")
    );

    return { lottery, tournament };
  }

  it("returns no penalty when a table has no eligible candidates", async function () {
    const { lottery, tournament } = await deployLotteryAndTournament();
    const result = await lottery.calculatePenalty(
      tournament.address,
      1,
      1,
      777
    );

    expect(result.resource.toNumber()).to.be.within(0, 3);
    expect(result.colonyId.toString()).to.equal("0");
    expect(result.penaltyAmount.toString()).to.equal("0");
  });

  it("exposes calculation only and has no mutation authority", async function () {
    const { lottery } = await deployLotteryAndTournament();
    const functions = Object.keys(lottery.interface.functions);

    expect(functions).to.include(
      "calculatePenalty(address,uint256,uint256,uint256)"
    );
    expect(
      functions.some((signature) =>
        /apply|set|owner|transfer/i.test(signature)
      )
    ).to.equal(false);
  });
});
