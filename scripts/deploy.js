const { ethers, network } = require("hardhat");

async function deployContract(name, args = []) {
  const factory = await ethers.getContractFactory(name);
  const contract = await factory.deploy(...args);
  await contract.deployed();
  console.log(`${name}: ${contract.address}`);
  return contract;
}

async function deployLocal() {
  const [deployer] = await ethers.getSigners();
  const premiumDeposit = ethers.utils.parseEther("0.5");
  const minimumProvide = ethers.utils.parseEther("0.5");
  const minimumReserve = ethers.utils.parseEther("2");
  const maxClaim = ethers.utils.parseEther("16");

  const wethToken = await deployContract("TestToken");
  const aWethToken = await deployContract("aTestToken");
  const poolMock = await deployContract("PoolMock");
  await (await poolMock.setTestTokens(wethToken.address, aWethToken.address)).wait();

  const poolAddressesProviderMock = await deployContract("PoolAddressesProviderMock");
  await (await poolAddressesProviderMock.setPoolImpl(poolMock.address)).wait();

  const lendingPoolAddressesProviderMock = await deployContract("LendingPoolAddressesProviderMock", [
    poolMock.address,
  ]);
  const protocolDataProviderMock = await deployContract("ProtocolDataProviderMock", [
    aWethToken.address,
  ]);
  const oracleMock = await deployContract("OracleMock", [deployer.address]);
  const wethGateway = await deployContract("WethGatewayTest");
  await (await wethGateway.setValues(wethToken.address, aWethToken.address)).wait();

  const oracleGateway = await deployContract("OracleGateway", [deployer.address, oracleMock.address]);
  const premiumGenerator = await deployContract("PremiumGeneratorAaveV2", [
    lendingPoolAddressesProviderMock.address,
    protocolDataProviderMock.address,
    deployer.address,
    wethGateway.address,
    premiumDeposit,
  ]);

  const reserve = await deployContract("Reserve", [
    deployer.address,
    premiumGenerator.address,
    wethGateway.address,
    minimumProvide,
    minimumReserve,
    maxClaim,
    oracleMock.address,
    oracleGateway.address,
  ]);

  await (await oracleMock.setReserve(reserve.address)).wait();
  await (await premiumGenerator.setReserve(reserve.address)).wait();
  await (await oracleGateway.setReserve(reserve.address)).wait();

  console.log(`Deployed local stack on ${network.name}`);
}

async function main() {
  await deployLocal();
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
