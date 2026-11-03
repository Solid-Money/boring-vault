const { ethers } = require('hardhat')

const balancerVault = '0xBA12222222228d8Ba445958a75a0704d566BF2C8'
const vault = '0xF88Ce04C3ef43F3501fA99eE06a5473f5ef33BED'
const authorityAddress = '0x2B7e98a2FC5f9B61adCd6D19049A559922A788B4'

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
