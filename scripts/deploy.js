const { ethers, network } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function deployContract(name, args = []) {
  const factory = await ethers.getContractFactory(name);
  const contract = await factory.deploy(...args);
  await contract.deployed();
  console.log(`${name}: ${contract.address}`);
  return contract;
}

async function main() {
  const deploymentBlock = (await ethers.provider.getBlockNumber()) + 1;
  const tournamentId = process.env.TOURNAMENT_ID || "1";
  const entryDeposit = process.env.ENTRY_DEPOSIT_ETH
    ? ethers.utils.parseEther(process.env.ENTRY_DEPOSIT_ETH)
    : ethers.utils.parseEther("1");
  const vrfRequestTimeout = process.env.VRF_REQUEST_TIMEOUT_SECONDS || "3600";

  let stETHAddress;
  if (network.name === "hardhat" || network.name === "localhost") {
    const stETH = await deployContract("StETHMock");
    stETHAddress = stETH.address;
  } else {
    if (network.config.chainId !== 1) {
      throw new Error("stETH tournament deployment is supported only on Ethereum mainnet");
    }
    stETHAddress =
      process.env.STETH_ADDRESS || "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84";
  }
  const yieldAdapter = await deployContract("StETHYieldAdapter", [
    stETHAddress,
    process.env.LIDO_REFERRAL_ADDRESS || ethers.constants.AddressZero,
  ]);
  const landLordImplementation = await deployContract("LandLord");

  const tournament = await deployContract("TournamentManager", [
    yieldAdapter.address,
    landLordImplementation.address,
    tournamentId,
    entryDeposit,
  ]);
  await (await yieldAdapter.setController(tournament.address)).wait();

  const battleManager = await deployContract("BattleManager", [
    tournament.address,
    tournamentId,
  ]);
  await (await tournament.setBattleManager(battleManager.address)).wait();
  await (await tournament.setVrfRequestTimeout(vrfRequestTimeout)).wait();

  let vrfProvider;
  if (network.name === "hardhat" || network.name === "localhost") {
    vrfProvider = await deployContract("VRFProviderMock", [
      tournament.address,
    ]);
    await (await tournament.setVrfProvider(vrfProvider.address)).wait();
  } else {
    const required = [
      "VRF_COORDINATOR",
      "VRF_KEY_HASH",
      "VRF_SUBSCRIPTION_ID",
      "VRF_REQUEST_CONFIRMATIONS",
      "VRF_CALLBACK_GAS_LIMIT",
    ];
    for (const name of required) {
      if (!process.env[name]) {
        throw new Error(`Missing required production VRF setting: ${name}`);
      }
    }

    vrfProvider = await deployContract("ChainlinkVRFProvider", [
      tournament.address,
      process.env.VRF_COORDINATOR,
      process.env.VRF_KEY_HASH,
      process.env.VRF_SUBSCRIPTION_ID,
      process.env.VRF_REQUEST_CONFIRMATIONS,
      process.env.VRF_CALLBACK_GAS_LIMIT,
    ]);
    await (await tournament.setVrfProvider(vrfProvider.address)).wait();
  }

  const { chainId } = await ethers.provider.getNetwork();
  const manifest = {
    chainId: chainId.toString(),
    deploymentBlock: deploymentBlock.toString(),
    tournamentAddress: tournament.address,
    battleManagerAddress: battleManager.address,
    vrfProviderAddress: vrfProvider.address,
    yieldAdapterAddress: yieldAdapter.address,
    landLordImplementationAddress: landLordImplementation.address,
  };
  const manifestPath = path.resolve(
    process.env.DEPLOYMENT_MANIFEST_PATH ||
      path.join("deployments", `${network.name}.json`)
  );
  fs.mkdirSync(path.dirname(manifestPath), { recursive: true });
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);

  console.log(`Deployed tournament stack on ${network.name}`);
  console.log(`Deployment manifest: ${manifestPath}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
