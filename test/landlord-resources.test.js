const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("LandLord four-resource model", function () {
  async function deployLandLord(overrides = {}, createdRound = 0) {
    const [lord, controller, outsider] = await ethers.getSigners();
    const LandLord = await ethers.getContractFactory("LandLord");
    const landLord = await LandLord.deploy();
    await landLord.deployed();
    const starting = {
      gold: overrides.gold ?? 1000,
      attack: overrides.attack ?? 0,
      defense: overrides.defense ?? 0,
      mining: overrides.mining ?? 0,
      infrastructure: overrides.infrastructure ?? 0,
    };
    await landLord.initialize(lord.address, controller.address, createdRound, starting);
    return { landLord, lord, controller, outsider };
  }

  async function expectRevert(promise, reason) {
    try {
      await promise;
      expect.fail("expected revert");
    } catch (error) {
      expect(error.message).to.include(reason);
    }
  }

  it("stores gold and the four approved allocations", async function () {
    const { landLord } = await deployLandLord({
      gold: 100, attack: 80, defense: 70, mining: 60,
      infrastructure: 50,
    });
    const r = await landLord.getResources();
    expect(r.gold.toString()).to.equal("100");
    expect(r.attack.toString()).to.equal("80");
    expect(r.defense.toString()).to.equal("70");
    expect(r.mining.toString()).to.equal("60");
    expect(r.infrastructure.toString()).to.equal("50");
    expect(r.food).to.equal(undefined);
    expect(r.army).to.equal(undefined);
  });

  it("permanently spends gold 1:1 across all categories", async function () {
    const { landLord, controller } = await deployLandLord({ gold: 100 });
    await landLord.connect(controller).allocateResources(20, 15, 25, 40, 4);
    const r = await landLord.getResources();
    expect(r.gold.toString()).to.equal("0");
    expect(r.attack.toString()).to.equal("20");
    expect(r.defense.toString()).to.equal("15");
    expect(r.mining.toString()).to.equal("25");
    expect(r.infrastructure.toString()).to.equal("40");
  });

  it("rejects over-allocation atomically and rejects non-controller calls", async function () {
    const { landLord, controller, outsider } = await deployLandLord({ gold: 99 });
    await expectRevert(
      landLord.connect(controller).allocateResources(20, 15, 25, 40, 1),
      "InsufficientGold"
    );
    await expectRevert(
      landLord.connect(outsider).allocateResources(1, 0, 0, 0, 1),
      "not controller"
    );
    expect((await landLord.getGold()).toString()).to.equal("99");
  });

  it("applies the piecewise Infrastructure curve and effect caps", async function () {
    const { landLord } = await deployLandLord({ infrastructure: 100 });
    expect((await landLord.infrastructureBonusBps(99)).toString()).to.equal("990");
    expect((await landLord.infrastructureBonusBps(100)).toString()).to.equal("1000");
    expect((await landLord.infrastructureBonusBps(101)).toString()).to.equal("1005");
    expect((await landLord.infrastructureBonusBps(500)).toString()).to.equal("3000");
    expect((await landLord.infrastructureBonusBps(1500)).toString()).to.equal("5000");
    expect((await landLord.infrastructureBonusBps(999999)).toString()).to.equal("5000");
  });

  it("delays new Mining and its Infrastructure boost until the next round", async function () {
    const { landLord, controller } = await deployLandLord({ gold: 300 });
    await landLord.connect(controller).allocateResources(0, 0, 200, 100, 2);
    expect((await landLord.previewMiningYield()).toString()).to.equal("0");
    expect((await landLord.connect(controller).callStatic.settleMining(1)).toString())
      .to.equal("0");
    await landLord.connect(controller).settleMining(1);
    // 200 * 5% = 10, boosted by 10% Infrastructure = 11.
    expect((await landLord.previewMiningYield()).toString()).to.equal("11");
    await landLord.connect(controller).settleMining(2);
    expect((await landLord.getGold()).toString()).to.equal("11");
  });

  it("rounds Mining yield down and prevents duplicate settlement", async function () {
    const { landLord, controller } = await deployLandLord({ gold: 99, mining: 99 });
    expect((await landLord.connect(controller).callStatic.settleMining(1)).toString())
      .to.equal("4");
    await landLord.connect(controller).settleMining(1);
    await expectRevert(landLord.connect(controller).settleMining(1), "RoundAlreadySettled");
  });

  it("reduces population growth by one round for each successful BUILD", async function () {
    const { landLord, controller } = await deployLandLord();
    expect((await landLord.populationForRound(5)).toString()).to.equal("260");
    await landLord.connect(controller).applyBuildAction(1);
    await landLord.connect(controller).applyBuildAction(3);
    expect((await landLord.populationForRound(5)).toString()).to.equal("160");
    expect((await landLord.getResourceStats(10)).population.toString()).to.equal("410");
    await expectRevert(
      landLord.connect(controller).applyBuildAction(3),
      "BuildAlreadyApplied"
    );
  });

  it("eliminates when gold equals the round population threshold", async function () {
    const atThreshold = await deployLandLord({ gold: 260 });
    const aboveThreshold = await deployLandLord({ gold: 261 });
    expect(await atThreshold.landLord.isEliminatedByResourcesForRound(5)).to.equal(true);
    expect(await aboveThreshold.landLord.isEliminatedByResourcesForRound(5)).to.equal(false);
  });

});
