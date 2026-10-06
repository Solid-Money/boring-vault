const { ethers } = require('hardhat')

const boringVault = '0xf9039d4f49686F34936b6937D13bBbe413f910c4'
const authorityAddress = '0x977b101F21eAB9CF7C50e943786279ee2D7BdA92'
const accountant = '0x803ed5a218a7704fC8697d36079F70df974Abb11'

async function main() {
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
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
