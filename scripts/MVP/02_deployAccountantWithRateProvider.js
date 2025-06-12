const { ethers } = require('hardhat')

const vaultAddress = '0x75333830E7014e909535389a6E5b0C02aA62ca27'
const payoutAddress = '0x3B694d634981Ace4B64a27c48bffe19f1447779B'
const startingExchangeRate = 1000000
const baseTokenAddress = '0xc6Bc407706B7140EE8Eef2f86F9504651b63e7f9'
const allowedExchangeRateChangeUpper = 20000
const allowedExchangeRateChangeLower = 1
const minimumUpdateDelayInSeconds = 1000
const platformFee = 1000
const performanceFee = 1000

const authorityAddress = '0x9ba8969613F3Ea41dE962054A8Faa50ae54F5956'

async function main() {
  console.log('Deploying AccountantWithRateProviders...')
  const [deployer] = await ethers.getSigners()

  // Deploy AccountantWithRateProviders
  const Accountant = await ethers.getContractFactory('AccountantWithRateProviders')
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
