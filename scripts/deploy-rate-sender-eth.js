const { ethers } = require('hardhat')

async function main() {
  const lzEndpoint = '0x1a44076050125825900e736c501f859c50fE728c' // LayerZero mainnet ETH
  const vaultAddr = '0x242d74d15eF015D2138a23ab67b6a1278A6B535A'

  const VaultRateSender = await ethers.getContractFactory('VaultRateSender')
  const sender = await VaultRateSender.deploy(lzEndpoint, vaultAddr)
  await sender.deployed()

  console.log('VaultRateSender deployed at:', sender.address)
}
main()
