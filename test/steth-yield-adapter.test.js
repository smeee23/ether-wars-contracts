const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("StETHYieldAdapter", function () {
  async function expectRevert(promise, reason) {
    try {
      await promise;
      expect.fail("expected transaction to revert");
    } catch (error) {
      expect(error.message).to.include(reason);
    }
  }

  async function deployAdapter() {
    const [owner, controller, alice] = await ethers.getSigners();
    const StETH = await ethers.getContractFactory("StETHMock");
    const Adapter = await ethers.getContractFactory("StETHYieldAdapter");
    const stETH = await StETH.deploy();
    const adapter = await Adapter.deploy(
      stETH.address,
      ethers.constants.AddressZero
    );
    await adapter.setController(controller.address);
    return { owner, controller, alice, stETH, adapter };
  }

  it("converts controller-supplied ETH to stETH", async function () {
    const { controller, stETH, adapter } = await deployAdapter();
    const amount = ethers.utils.parseEther("1");

    await adapter.connect(controller).depositETH({ value: amount });
    expect((await stETH.balanceOf(adapter.address)).toString()).to.equal(
      amount.toString()
    );
    expect(await adapter.principalAsset()).to.equal(stETH.address);
  });

  it("pulls approved stETH and returns withdrawals only as stETH", async function () {
    const { controller, alice, stETH, adapter } = await deployAdapter();
    const amount = ethers.utils.parseEther("1");
    await stETH.mint(alice.address, amount);
    await stETH.connect(alice).approve(adapter.address, amount);

    await adapter.connect(controller).depositAsset(alice.address, amount);
    await adapter.connect(controller).withdrawAsset(alice.address, amount);

    expect((await stETH.balanceOf(alice.address)).toString()).to.equal(
      amount.toString()
    );
    expect((await ethers.provider.getBalance(adapter.address)).toString()).to.equal("0");
  });

  it("rejects direct ETH and non-controller asset movement", async function () {
    const { alice, adapter } = await deployAdapter();
    await expectRevert(
      alice.sendTransaction({ to: adapter.address, value: 1 }),
      "DirectEthNotAccepted"
    );
    await expectRevert(
      adapter.connect(alice).withdrawAsset(alice.address, 1),
      "NotController"
    );
  });
});
