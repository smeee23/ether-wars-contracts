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
    const { landLord, lord } = await deployLandLord({
      gold: 100,
      food: 1,
      water: 1,
      oxygen: 1,
      shelter: 1,
      army: 1,
    });

    await landLord.connect(lord).allocateGold(FOOD, 10);
    await landLord.connect(lord).allocateGold(WATER, 20);
    await landLord.connect(lord).allocateGold(OXYGEN, 15);
    await landLord.connect(lord).allocateGold(SHELTER, 25);
    await landLord.connect(lord).allocateGold(ARMY, 30);

    const resources = await landLord.getResources();
    expect(resources.gold.toString()).to.equal("0");
    expect(resources.food.toString()).to.equal("11");
    expect(resources.water.toString()).to.equal("21");
    expect(resources.oxygen.toString()).to.equal("16");
    expect(resources.shelter.toString()).to.equal("26");
    expect(resources.army.toString()).to.equal("31");
  });

  it("keeps deprecated replenish wrappers on 1:1 allocation semantics", async function () {
    const { landLord, lord } = await deployLandLord({
      gold: 20,
      food: 1,
      water: 1,
      oxygen: 1,
      shelter: 1,
      army: 1,
    });

    await landLord.connect(lord).spendGoldToReplenish(FOOD, 2);

    const resources = await landLord.getResources();
    expect(resources.gold.toString()).to.equal("18");
    expect(resources.food.toString()).to.equal("3");
  });

  it("derives population from round number and applies upkeep to survival resources", async function () {
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

    await landLord.connect(controller).applyRoundUpkeep(lord.address, 1);

    const resources = await landLord.getResources();
    expect(resources.gold.toString()).to.equal("1");
    expect(resources.food.toString()).to.equal("14");
    expect(resources.water.toString()).to.equal("14");
    expect(resources.oxygen.toString()).to.equal("14");
    expect(resources.shelter.toString()).to.equal("16");
    expect(resources.army.toString()).to.equal("18");
    expect(await landLord.isEliminatedByResources()).to.equal(false);
  });

  it("stores BUILD support credits and applies upkeep from the effective round", async function () {
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
    expect((await landLord.effectiveRoundForSupport(10)).toString()).to.equal("7");

    await landLord.connect(controller).applyRoundUpkeep(lord.address, 10);

    const resources = await landLord.getResources();
    expect(resources.gold.toString()).to.equal("1");
    expect(resources.food.toString()).to.equal("94");
    expect(resources.water.toString()).to.equal("94");
    expect(resources.oxygen.toString()).to.equal("94");
    expect(resources.shelter.toString()).to.equal("96");
    expect(resources.army.toString()).to.equal("98");
  });

  it("does not expose contract-level building counters or building-derived stats", async function () {
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
    expect(stats.defensePower.toString()).to.equal("20");
  });

  it("flags elimination when oxygen reaches zero", async function () {
    const { landLord, controller, lord } = await deployLandLord({
      gold: 1,
      food: 20,
      water: 20,
      oxygen: 3,
      shelter: 20,
      army: 20,
    });

    expect(await landLord.isEliminatedByResources()).to.equal(false);

    await landLord.connect(controller).applyRoundUpkeep(lord.address, 1);

    const resources = await landLord.getResources();
    expect(resources.oxygen.toString()).to.equal("0");
    expect(await landLord.isEliminatedByResources()).to.equal(true);
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
    expect(await landLord.canSurviveNextRound()).to.equal(false);
  });
});
