const { ethers } = require('hardhat')

const authorityAddress = '0x7F66AF3C7B7D80d6d4be937dE81cad42C0277eE3' // Base: from deployAll.js output
const boringQueueWithTrackingAddress = '0xf68057c26eaF1F49800EaE86046B2b70Bd8Ded06' // Base: from 05_deployBoringQueue.js output

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
