const { expect } = require("chai");
const fs = require("fs");
const path = require("path");

describe("Production VRF deployment configuration", function () {
  it("requires real Chainlink configuration and installs the timeout", function () {
    const source = fs.readFileSync(
      path.join(__dirname, "..", "scripts", "deploy.js"),
      "utf8"
    );

    expect(source).to.include('deployContract("ChainlinkVRFProvider"');
    expect(source).to.include("VRF_COORDINATOR");
    expect(source).to.include("VRF_KEY_HASH");
    expect(source).to.include("VRF_SUBSCRIPTION_ID");
    expect(source).to.include("VRF_REQUEST_CONFIRMATIONS");
    expect(source).to.include("VRF_CALLBACK_GAS_LIMIT");
    expect(source).to.include("VRF_REQUEST_TIMEOUT_SECONDS");
    expect(source).to.include("tournament.setVrfRequestTimeout");
    expect(source).to.include("tournament.setVrfProvider");
    expect(source).to.include('deployContract("StETHYieldAdapter"');
    expect(source).to.include("StETHMock");
    expect(source).to.include("STETH_ADDRESS");
    expect(source).to.include("LIDO_REFERRAL_ADDRESS");
    expect(source).to.include("network.config.chainId !== 1");
  });
});
