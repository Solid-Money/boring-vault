const { ethers } = require('hardhat')
const deployment = require('./deployment').load()

const authorityAddress = deployment.address('RolesAuthority')
const boringQueueWithTrackingAddress = deployment.address('BoringQueue')

async function main() {
  await deployment.check(ethers)
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
  deployment.save('BoringSolver', boringSolver.address)
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
