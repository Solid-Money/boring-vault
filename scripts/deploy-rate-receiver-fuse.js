const { ethers } = require('hardhat')

async function main() {
  const lzEndpoint = '0x1a44076050125825900e736c501f859c50fE728c' // LayerZero Fuse
  const sourceEid = 1;

  const VaultRateReceiver = await ethers.getContractFactory('VaultRateReceiver')
  const receiver = await VaultRateReceiver.deploy(lzEndpoint, sourceEid)
  await receiver.deployed()

  console.log('VaultRateReceiver deployed at:', receiver.address)
}
main()
