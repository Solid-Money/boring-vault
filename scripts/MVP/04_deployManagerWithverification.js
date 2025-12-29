const { ethers } = require('hardhat')

const balancerVault = '0xBA12222222228d8Ba445958a75a0704d566BF2C8'
const vault = '0x3c0c8f95D7f4265B2dc5575eBc37a6945c7a7A31'
const authorityAddress = '0x9FcD641048F06d070A50a70EE4C941deCBCF7CfB'

async function main() {
  const [deployer] = await ethers.getSigners()

  // Deploy Arctic Architecture Lens
  const ManagerWithMerkleVerification = await ethers.getContractFactory('src/base/Roles/ManagerWithMerkleVerification.sol:ManagerWithMerkleVerification')

  const manager = await ManagerWithMerkleVerification.deploy(
    deployer.address,
    vault,
    balancerVault
  )
  await manager.deployed()

  console.log(`Manager deployed at:`, manager.address)

  // Set authority on the manager
  await manager.setAuthority(authorityAddress)
  console.log('Manager authority updated')
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
