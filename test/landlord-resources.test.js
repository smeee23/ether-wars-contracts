const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("LandLord resource model", function () {
  async function deployLandLord(startingResources) {
    const [lord, controller] = await ethers.getSigners();
    const LandLord = await ethers.getContractFactory("LandLord");
    const landLord = await LandLord.deploy();
    await landLord.deployed();

    await landLord.initialize(lord.address, controller.address, startingResources);

    return { landLord, lord, controller };
  }

  it("stores only gold, food, water, shelter, and army", async function () {
    const { landLord } = await deployLandLord({
      gold: 100,
      food: 90,
      water: 80,
      shelter: 70,
      army: 60,
    });

    const resources = await landLord.getResources();

    expect(resources.gold.toString()).to.equal("100");
    expect(resources.food.toString()).to.equal("90");
    expect(resources.water.toString()).to.equal("80");
    expect(resources.shelter.toString()).to.equal("70");
    expect(resources.army.toString()).to.equal("60");
    expect(resources.population).to.equal(undefined);
  });

  it("spends gold to replenish survival resources only", async function () {
    const { landLord, lord } = await deployLandLord({
      gold: 20,
      food: 1,
      water: 1,
      shelter: 1,
      army: 1,
    });

    await landLord.connect(lord).spendGoldToReplenish(0, 2);

    const resources = await landLord.getResources();
    expect(resources.gold.toString()).to.equal("18");
    expect(resources.food.toString()).to.equal("21");
    expect(resources.water.toString()).to.equal("1");
    expect(resources.shelter.toString()).to.equal("1");
    expect(resources.army.toString()).to.equal("1");
  });

  it("derives population and applies upkeep to survival resources", async function () {
    const { landLord, controller, lord } = await deployLandLord({
      gold: 1,
      food: 20,
      water: 20,
      shelter: 20,
      army: 20,
    });

    expect(await landLord.isEliminatedByResources()).to.equal(false);
    expect((await landLord["getPopulationEstimate()"]()).toString()).to.equal("10");
    expect((await landLord["getPopulationEstimate(uint256)"](5)).toString()).to.equal("15");

    await landLord.connect(controller).applyRoundUpkeep(lord.address, 1);

    const resources = await landLord.getResources();
    expect(resources.gold.toString()).to.equal("1");
    expect(resources.food.toString()).to.equal("14");
    expect(resources.water.toString()).to.equal("14");
    expect(resources.shelter.toString()).to.equal("16");
    expect(resources.army.toString()).to.equal("18");
    expect(await landLord.isEliminatedByResources()).to.equal(false);
  });

  it("can skip round decay while preserving production", async function () {
    const { landLord, controller, lord } = await deployLandLord({
      gold: 1,
      food: 20,
      water: 20,
      shelter: 20,
      army: 20,
    });

    await landLord.connect(controller).applyRoundUpkeepWithDecaySkip(
      lord.address,
      1,
      true
    );

    const resources = await landLord.getResources();
    expect(resources.gold.toString()).to.equal("1");
    expect(resources.food.toString()).to.equal("20");
    expect(resources.water.toString()).to.equal("20");
    expect(resources.shelter.toString()).to.equal("20");
    expect(resources.army.toString()).to.equal("20");
    expect(await landLord.isEliminatedByResources()).to.equal(false);
  });

  it("flags elimination when any survival resource reaches zero", async function () {
    const { landLord, controller, lord } = await deployLandLord({
      gold: 1,
      food: 3,
      water: 20,
      shelter: 20,
      army: 20,
    });

    expect(await landLord.isEliminatedByResources()).to.equal(false);

    await landLord.connect(controller).applyRoundUpkeep(lord.address, 1);

    const resources = await landLord.getResources();
    expect(resources.food.toString()).to.equal("0");
    expect(await landLord.isEliminatedByResources()).to.equal(true);
  });

  it("flags elimination when gold reaches zero", async function () {
    const { landLord } = await deployLandLord({
      gold: 0,
      food: 20,
      water: 20,
      shelter: 20,
      army: 20,
    });

    expect(await landLord.isEliminatedByResources()).to.equal(true);
    expect(await landLord.canSurviveNextRound()).to.equal(false);
  });
});
