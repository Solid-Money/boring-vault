const { ethers } = require('hardhat')
const deployment = require('./deployment').load()

const boringVault = deployment.address('BoringVault')
const authorityAddress = deployment.address('RolesAuthority')
const accountant = deployment.address('Accountant')

async function main() {
  await deployment.check(ethers)
  const [deployer] = await ethers.getSigners()

  // Deploy Arctic Architecture Lens
  const BoringQueueWithTracking = await ethers.getContractFactory('src/base/Roles/BoringQueue/BoringOnChainQueueWithTracking.sol:BoringOnChainQueueWithTracking')

  const boringQueueWithTracking = await BoringQueueWithTracking.deploy(
    deployer.address,
    authorityAddress,
    boringVault,
    accountant,
    true,
  )
  await boringQueueWithTracking.deployed()

  console.log(`Boring Queue With Tracking deployed at:`, boringQueueWithTracking.address)
  deployment.save('BoringQueue', boringQueueWithTracking.address)
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
