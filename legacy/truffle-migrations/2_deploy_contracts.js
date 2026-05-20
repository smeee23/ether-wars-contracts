var Reserve = artifacts.require("Reserve");
var PoolAddressesProviderMock = artifacts.require("PoolAddressesProviderMock");
var PoolMock = artifacts.require("PoolMock");
var WethGatewayTest = artifacts.require("WethGatewayTest");
var OracleGateway = artifacts.require("OracleGateway");
var aTestToken = artifacts.require("aTestToken");
var TestToken = artifacts.require("TestToken");
var OracleMock = artifacts.require("OracleMock");

var PremiumGeneratorAaveV2 = artifacts.require("PremiumGeneratorAaveV2");
var LendingPoolAddressesProviderMock = artifacts.require("LendingPoolAddressesProviderMock");
var ProtocolDataProviderMock = artifacts.require("ProtocolDataProviderMock");

require("dotenv").config({path: "../.env"});

module.exports = async function(deployer, network, accounts){
  let poolAddressesProviderAddr;
  let wethGatewayAddr;
  let multiSig;

  if(["matic_mumbai"].includes(network) ){

    const premiumDeposit = web3.utils.toWei("0.1", "ether");
    const minimumProvide = web3.utils.toWei("0.1", "ether");
    const minimumReserve = web3.utils.toWei("0.01", "ether");
    const maxClaim = web3.utils.toWei("4", "ether");

    const lendingPoolAddressesProvider = "0x178113104fEcbcD7fF8669a0150721e231F0FD4B";
    const protocolDataProvider = "0xFA3bD19110d986c5e5E9DD5F69362d05035D045B";
    wethGatewayAddr = "0xee9eE614Ad26963bEc1Bec0D2c92879ae1F209fA";
    let chainlinkFunctionsConsumer = "0x3f47DF60715CC81B0C6E1B7Bc2f51269687cA542"
    multiSig = "0x78726673245fdb56425c8bd782f6FaA3E447625A";

    await deployer.deploy(OracleGateway, multiSig, chainlinkFunctionsConsumer);
    oracleGateway = await OracleGateway.deployed();

    await deployer.deploy(PremiumGeneratorAaveV2, lendingPoolAddressesProvider, protocolDataProvider, multiSig, wethGatewayAddr, premiumDeposit);
    premiumGeneratorAaveV2 = await PremiumGeneratorAaveV2.deployed();

    await deployer.deploy(Reserve, multiSig, premiumGeneratorAaveV2.address, wethGatewayAddr, minimumProvide, minimumReserve, maxClaim, chainlinkFunctionsConsumer, oracleGateway.address);
    reserve = await Reserve.deployed();

    await premiumGeneratorAaveV2.setReserve(reserve.address);
    await oracleGateway.setReserve(reserve.address);
  }

  else {
    await deployer.deploy(PoolMock);
    await deployer.deploy(WethGatewayTest);
    await deployer.deploy(PoolAddressesProviderMock);
    await deployer.deploy(aTestToken);
    await deployer.deploy(TestToken);
    await deployer.deploy(LendingPoolAddressesProviderMock, PoolMock.address);
    await deployer.deploy(ProtocolDataProviderMock, aTestToken.address);
    multiSig = accounts[0];
    await deployer.deploy(OracleMock, multiSig);

    wethGatewayTest = await WethGatewayTest.deployed();
    oracleMock = await OracleMock.deployed();
    poolAddressesProviderMock = await PoolAddressesProviderMock.deployed();
    await poolAddressesProviderMock.setPoolImpl(PoolMock.address);
    poolAddressesProviderAddr = poolAddressesProviderMock.address;
    lendingPoolAddressesProviderMock = await LendingPoolAddressesProviderMock.deployed();
    protocolDataProviderMock = await ProtocolDataProviderMock.deployed();
    wethGatewayAddr = wethGatewayTest.address;

    await deployer.deploy(OracleGateway, multiSig, oracleMock.address);
    oracleGateway = await OracleGateway.deployed();

    await deployer.deploy(PremiumGeneratorAaveV2, lendingPoolAddressesProviderMock.address, protocolDataProviderMock.address, multiSig, wethGatewayAddr, "1000000000000000000");
    premiumGeneratorAaveV2 = await PremiumGeneratorAaveV2.deployed();

    await deployer.deploy(Reserve, multiSig, premiumGeneratorAaveV2.address, wethGatewayAddr, "100000000000000", "100000000000000000000", "100000000000", oracleMock.address, oracleGateway.address);
  }


};
