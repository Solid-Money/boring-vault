const { ethers } = require('hardhat')

const vaultAddress = '0xBd37f551CEb90369dcf1e46Ddb60937B0AdEE107'
const payoutAddress = '0x3B694d634981Ace4B64a27c48bffe19f1447779B'
const authorityAddress = '0x4F85400195a87dFD92bCa1922068609998bccAEe'
const baseTokenAddress = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913'

const startingExchangeRate = 1000000
const allowedExchangeRateChangeUpper = 20000
const allowedExchangeRateChangeLower = 1
const minimumUpdateDelayInSeconds = 1000
const platformFee = 0
const performanceFee = 1000

async function main() {
  console.log('Deploying AccountantWithRateProviders...')
  const [deployer] = await ethers.getSigners()

  // Deploy AccountantWithRateProviders
  const Accountant = await ethers.getContractFactory('src/base/Roles/AccountantWithRateProviders.sol:AccountantWithRateProviders')
  const accountant = await Accountant.deploy(
    deployer.address,
    vaultAddress,
    payoutAddress,
    startingExchangeRate,
    baseTokenAddress,
    allowedExchangeRateChangeUpper,
    allowedExchangeRateChangeLower,
    minimumUpdateDelayInSeconds,
    platformFee,
    performanceFee
  )
  await accountant.deployed()

  console.log(`Accountant deployed at:`, accountant.address)

  // Set authority on the accountant
  await accountant.setAuthority(authorityAddress)
  console.log('Accountant authority updated')
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
