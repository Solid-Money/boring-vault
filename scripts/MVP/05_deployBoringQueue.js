const { ethers } = require('hardhat')

const boringVault = '0x1c6B29c8ac1E12A34D74DdaFCF016246d6aEdfff' // Base: from deployAll.js output
const authorityAddress = '0x7F66AF3C7B7D80d6d4be937dE81cad42C0277eE3' // Base: from deployAll.js output
const accountant = '0x23710C9fdF34b7E1eF28A92a19F9fdC0aC99518c' // Base: from deployAll.js output

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
