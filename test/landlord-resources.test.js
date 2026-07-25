const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("LandLord five-resource model", function () {
  async function deployLandLord(overrides = {}, createdRound = 0) {
    const [lord, controller, outsider] = await ethers.getSigners();
    const LandLord = await ethers.getContractFactory("LandLord");
    const landLord = await LandLord.deploy();
    await landLord.deployed();
    const starting = {
      gold: overrides.gold ?? 1000,
      terraform: overrides.terraform ?? 0,
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

  it("stores gold and the five approved allocations", async function () {
    const { landLord } = await deployLandLord({
      gold: 100, terraform: 90, attack: 80, defense: 70, mining: 60,
      infrastructure: 50,
    });
    const r = await landLord.getResources();
    expect(r.gold.toString()).to.equal("100");
    expect(r.terraform.toString()).to.equal("90");
    expect(r.attack.toString()).to.equal("80");
    expect(r.defense.toString()).to.equal("70");
    expect(r.mining.toString()).to.equal("60");
    expect(r.infrastructure.toString()).to.equal("50");
    expect(r.food).to.equal(undefined);
    expect(r.army).to.equal(undefined);
  });

  it("permanently spends gold 1:1 across all categories", async function () {
    const { landLord, controller } = await deployLandLord({ gold: 100 });
    await landLord.connect(controller).allocateResources(10, 20, 15, 25, 30);
    const r = await landLord.getResources();
    expect(r.gold.toString()).to.equal("0");
    expect(r.terraform.toString()).to.equal("10");
    expect(r.attack.toString()).to.equal("20");
    expect(r.defense.toString()).to.equal("15");
    expect(r.mining.toString()).to.equal("25");
    expect(r.infrastructure.toString()).to.equal("30");
  });

  it("rejects over-allocation atomically and rejects non-controller calls", async function () {
    const { landLord, controller, outsider } = await deployLandLord({ gold: 99 });
    await expectRevert(
      landLord.connect(controller).allocateResources(10, 20, 15, 25, 30),
      "InsufficientGold"
    );
    await expectRevert(
      landLord.connect(outsider).allocateResources(1, 0, 0, 0, 0),
      "not controller"
    );
    expect((await landLord.getGold()).toString()).to.equal("99");
  });

  it("uses Attack only for attack bonus and Defense only for defense bonus", async function () {
    const { landLord } = await deployLandLord({
      gold: 0, attack: 250, defense: 500, infrastructure: 0,
    });
    expect((await landLord.getAttackBonus()).toString()).to.equal("10");
    expect((await landLord.getDefenseBonus()).toString()).to.equal("20");
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
    await landLord.connect(controller).allocateResources(0, 0, 0, 200, 100);
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

  it("retains 10 + round population and BUILD credits only reduce Terraform pressure", async function () {
    const { landLord, controller } = await deployLandLord({ terraform: 100 });
    expect((await landLord.populationForRound(5)).toString()).to.equal("15");
    expect((await landLord.terraformRequirement(10)).toString()).to.equal("90");
    await landLord.connect(controller).applyBuildAction();
    await landLord.connect(controller).applyBuildAction();
    expect((await landLord.terraformRequirement(10)).toString()).to.equal("75");
    expect((await landLord.getResources()).terraform.toString()).to.equal("100");
  });

  it("scales Terraform gold drain with shortage severity and reduces it with Infrastructure", async function () {
    const mild = await deployLandLord({ gold: 1000, terraform: 44 });
    const severe = await deployLandLord({ gold: 1000, terraform: 0 });
    const protectedColony = await deployLandLord({
      gold: 1000, terraform: 0, infrastructure: 1500,
    });
    const mildResult = await mild.landLord.connect(mild.controller)
      .callStatic.applyTerraformMaintenance(mild.lord.address, 1);
    const severeResult = await severe.landLord.connect(severe.controller)
      .callStatic.applyTerraformMaintenance(severe.lord.address, 1);
    const protectedResult = await protectedColony.landLord.connect(protectedColony.controller)
      .callStatic.applyTerraformMaintenance(protectedColony.lord.address, 1);
    expect(severeResult.drained.gt(mildResult.drained)).to.equal(true);
    expect(protectedResult.drained.lt(severeResult.drained)).to.equal(true);
  });

  it("eliminates when Terraform maintenance drains the last free gold", async function () {
    const { landLord, lord, controller } = await deployLandLord({ gold: 1 });
    const result = await landLord.connect(controller)
      .callStatic.applyTerraformMaintenance(lord.address, 1);
    expect(result.drained.toString()).to.equal("1");
    expect(result.eliminated).to.equal(true);
    await landLord.connect(controller).applyTerraformMaintenance(lord.address, 1);
    expect(await landLord.isEliminatedByResources()).to.equal(true);
  });
});
