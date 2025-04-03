require('@nomiclabs/hardhat-ethers')
require('@nomicfoundation/hardhat-foundry')
require('dotenv').config()
require('hardhat-preprocessor')
const fs = require('fs')

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  solidity: {
    version: '0.8.21',
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    mainnet: {
      url: process.env.MAINNET_RPC_URL,
      accounts: [process.env.PRIVATE_KEY],
      chainId: 1,
    },
    fuse: {
      url: process.env.FUSE_RPC_URL,
      accounts: [process.env.PRIVATE_KEY],
      chainId: 122,
    },
  },
  paths: {
    sources: './src',
    artifacts: './artifacts',
    cache: './cache',
  },
  preprocess: {
    eachLine: (hre) => ({
      transform: (line) => {
        if (line.match(/^\s*import /i)) {
          getRemappings().forEach(([find, replace]) => {
            // console.log(find, replace);
            if (line.match(find)) {
              line = line.replace(find, replace)
            }
          })
        }
        return line
      },
    }),
  },
}

function getRemappings() {
  return fs
    .readFileSync('remappings.txt', 'utf8')
    .split('\n')
    .filter(Boolean) // remove empty lines
    .map((line) => line.trim().split('='))
}
