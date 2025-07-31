const { ethers } = require('hardhat')

const balancerVault = '0xBA12222222228d8Ba445958a75a0704d566BF2C8'
const vault = '0x3e2cD0AeF639CD72Aff864b85acD5c07E2c5e3FA'

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
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
