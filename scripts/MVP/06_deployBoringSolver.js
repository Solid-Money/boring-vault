const { ethers } = require('hardhat')

const authorityAddress = '0x977b101F21eAB9CF7C50e943786279ee2D7BdA92'
const boringQueueWithTrackingAddress = '0xcfd7a4236ed557e9c2c03ce3256f091a0b60de28'

async function main() {
  const [deployer] = await ethers.getSigners()

  // Deploy Arctic Architecture Lens
  const BoringSolver = await ethers.getContractFactory('src/base/Roles/BoringQueue/BoringSolver.sol:BoringSolver')

  const boringSolver = await BoringSolver.deploy(
    deployer.address,
    authorityAddress,
    boringQueueWithTrackingAddress,
    true,
  )
  await boringSolver.deployed()

  console.log(`Boring Solver deployed at:`, boringSolver.address)
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
