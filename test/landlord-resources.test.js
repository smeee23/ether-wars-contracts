const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("LandLord resource model", function () {
  const FOOD = 0;
  const WATER = 1;
  const OXYGEN = 2;
  const SHELTER = 3;
  const ARMY = 4;

  async function deployLandLord(startingResources) {
    const [lord, controller] = await ethers.getSigners();
    const LandLord = await ethers.getContractFactory("LandLord");
    const landLord = await LandLord.deploy();
    await landLord.deployed();

    await landLord.initialize(lord.address, controller.address, startingResources);

    return { landLord, lord, controller };
  }

  it("stores only gold, food, water, oxygen, shelter, and army", async function () {
    const { landLord } = await deployLandLord({
      gold: 100,
      food: 90,
      water: 80,
      oxygen: 75,
      shelter: 70,
      army: 60,
    });

    const resources = await landLord.getResources();

    expect(resources.gold.toString()).to.equal("100");
    expect(resources.food.toString()).to.equal("90");
    expect(resources.water.toString()).to.equal("80");
    expect(resources.oxygen.toString()).to.equal("75");
    expect(resources.shelter.toString()).to.equal("70");
    expect(resources.army.toString()).to.equal("60");
    expect(resources.population).to.equal(undefined);
  });

  it("allocates gold 1:1 into each resource", async function () {
    const { landLord, controller } = await deployLandLord({
      gold: 100,
      food: 1,
      water: 1,
      oxygen: 1,
      shelter: 1,
      army: 1,
    });

    await landLord.connect(controller).allocateGoldByController(FOOD, 10);
    await landLord.connect(controller).allocateGoldByController(WATER, 20);
    await landLord.connect(controller).allocateGoldByController(OXYGEN, 15);
    await landLord.connect(controller).allocateGoldByController(SHELTER, 25);
    await landLord.connect(controller).allocateGoldByController(ARMY, 30);

    const resources = await landLord.getResources();
    expect(resources.gold.toString()).to.equal("0");
    expect(resources.food.toString()).to.equal("11");
    expect(resources.water.toString()).to.equal("21");
    expect(resources.oxygen.toString()).to.equal("16");
    expect(resources.shelter.toString()).to.equal("26");
    expect(resources.army.toString()).to.equal("31");
  });

  it("does not expose deprecated replenish wrappers", async function () {
    const { landLord, controller } = await deployLandLord({
      gold: 20,
      food: 1,
      water: 1,
      oxygen: 1,
      shelter: 1,
      army: 1,
    });

    await landLord.connect(controller).allocateGoldByController(FOOD, 2);

    const resources = await landLord.getResources();
    expect(resources.gold.toString()).to.equal("18");
    expect(resources.food.toString()).to.equal("3");
    expect(landLord.spendGoldToReplenish).to.equal(undefined);
    expect(landLord.replenishResource).to.equal(undefined);
  });

  it("derives population from round number and checks support without draining resources", async function () {
    const { landLord, controller, lord } = await deployLandLord({
      gold: 1,
      food: 20,
      water: 20,
      oxygen: 20,
      shelter: 20,
      army: 20,
    });

    expect(await landLord.isEliminatedByResources()).to.equal(false);
    expect((await landLord["getPopulationEstimate()"]()).toString()).to.equal("10");
    expect((await landLord.populationForRound(5)).toString()).to.equal("15");
    expect(await landLord.canSupportRound(1)).to.equal(true);

    await landLord.connect(controller).applyRoundUpkeep(lord.address, 1);

    const resources = await landLord.getResources();
    expect(resources.gold.toString()).to.equal("1");
    expect(resources.food.toString()).to.equal("20");
    expect(resources.water.toString()).to.equal("20");
    expect(resources.oxygen.toString()).to.equal("20");
    expect(resources.shelter.toString()).to.equal("20");
    expect(resources.army.toString()).to.equal("20");
    expect(await landLord.isEliminatedByResources()).to.equal(false);
  });

  it("stores BUILD support credits and checks support from the effective round", async function () {
    const { landLord, controller, lord } = await deployLandLord({
      gold: 1,
      food: 100,
      water: 100,
      oxygen: 100,
      shelter: 100,
      army: 100,
    });

    await landLord.connect(controller).applyBuildAction();
    await landLord.connect(controller).applyBuildAction();
    await landLord.connect(controller).applyBuildAction();

    expect((await landLord.supportCredits()).toString()).to.equal("3");
    expect((await landLord.effectiveRoundForSupport(10)).toString()).to.equal("4");

    const requirements = await landLord.supportRequirements(10);
    expect(requirements.foodRequired.toString()).to.equal("6");
    expect(requirements.waterRequired.toString()).to.equal("6");
    expect(requirements.oxygenRequired.toString()).to.equal("6");
    expect(requirements.shelterRequired.toString()).to.equal("6");
    expect(requirements.armyRequired.toString()).to.equal("6");

    await landLord.connect(controller).applyRoundUpkeep(lord.address, 10);

    const resources = await landLord.getResources();
    expect(resources.gold.toString()).to.equal("1");
    expect(resources.food.toString()).to.equal("100");
    expect(resources.water.toString()).to.equal("100");
    expect(resources.oxygen.toString()).to.equal("100");
    expect(resources.shelter.toString()).to.equal("100");
    expect(resources.army.toString()).to.equal("100");
  });

  it("does not expose contract-level building counters or defense stats", async function () {
    const { landLord } = await deployLandLord({
      gold: 1,
      food: 20,
      water: 20,
      oxygen: 20,
      shelter: 20,
      army: 20,
    });

    expect(landLord.getBuildings).to.equal(undefined);
    expect(landLord.buildFarm).to.equal(undefined);

    const stats = await landLord.getResourceStats(7);
    expect(stats.population.toString()).to.equal("17");
    expect(stats.attackPower.toString()).to.equal("20");
    expect(stats.defensePower).to.equal(undefined);
    expect(landLord.getDefensePower).to.equal(undefined);
    expect(landLord.getCityStats).to.equal(undefined);
  });

  it("flags support elimination when oxygen is below the required threshold", async function () {
    const { landLord, controller, lord } = await deployLandLord({
      gold: 1,
      food: 20,
      water: 20,
      oxygen: 5,
      shelter: 20,
      army: 20,
    });

    expect(await landLord.isEliminatedByResources()).to.equal(false);
    expect(await landLord.isEliminatedByResourcesForRound(1)).to.equal(true);

    await landLord.connect(controller).applyRoundUpkeep(lord.address, 1);

    const resources = await landLord.getResources();
    expect(resources.oxygen.toString()).to.equal("5");
    expect(await landLord.isEliminatedByResources()).to.equal(false);
    expect(await landLord.isEliminatedByResourcesForRound(1)).to.equal(true);
  });

  it("flags elimination when gold reaches zero", async function () {
    const { landLord } = await deployLandLord({
      gold: 0,
      food: 20,
      water: 20,
      oxygen: 20,
      shelter: 20,
      army: 20,
    });

    expect(await landLord.isEliminatedByResources()).to.equal(true);
    expect(await landLord.canSupportRound(1)).to.equal(false);
    expect(landLord.canSurviveNextRound).to.equal(undefined);
  });
});
