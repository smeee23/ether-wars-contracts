require("@nomiclabs/hardhat-ethers");
require("dotenv").config();

const accounts = (() => {
  if (process.env.PRIVATE_KEY) {
    return [process.env.PRIVATE_KEY];
  }

  if (process.env.MNEMONIC) {
    return {
      mnemonic: process.env.MNEMONIC,
    };
  }

  return [];
})();

module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: false,
        runs: 200,
      },
    },
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
  networks: {
    hardhat: {
      chainId: 31337,
    },
    localhost: {
      url: process.env.LOCALHOST_RPC_URL || "http://127.0.0.1:8545",
      accounts,
    },
    polygonMumbai: {
      url: process.env.POLYGON_MUMBAI_RPC_URL || "",
      accounts,
      chainId: 80001,
    },
    polygon: {
      url: process.env.POLYGON_RPC_URL || "",
      accounts,
      chainId: 137,
    },
  },
};
