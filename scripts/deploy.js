const { ethers, network } = require("hardhat");

async function deployContract(name, args = []) {
  const factory = await ethers.getContractFactory(name);
  const contract = await factory.deploy(...args);
  await contract.deployed();
  console.log(`${name}: ${contract.address}`);
  return contract;
}

async function main() {
  const tournamentId = process.env.TOURNAMENT_ID || "1";
  const entryDeposit = process.env.ENTRY_DEPOSIT_ETH
    ? ethers.utils.parseEther(process.env.ENTRY_DEPOSIT_ETH)
    : ethers.utils.parseEther("1");

  const yieldAdapter = await deployContract("NoYieldAdapter");
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

  if (network.name === "hardhat" || network.name === "localhost") {
    const vrfProvider = await deployContract("VRFProviderMock", [
      tournament.address,
    ]);
    await (await tournament.setVrfProvider(vrfProvider.address)).wait();
  }

  console.log(`Deployed tournament stack on ${network.name}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
