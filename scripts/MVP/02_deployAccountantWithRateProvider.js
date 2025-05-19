const { ethers } = require('hardhat')

const vaultAddress = '0x3e2cD0AeF639CD72Aff864b85acD5c07E2c5e3FA'
const payoutAddress = '0x3B694d634981Ace4B64a27c48bffe19f1447779B'
const startingExchangeRate = 1000000
const baseTokenAddress = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48'
const allowedExchangeRateChangeUpper = 10000
const allowedExchangeRateChangeLower = 1
const minimumUpdateDelayInSeconds = 1000
const platformFee = 1000
const performanceFee = 1000

const authorityAddress = '0x2a9bC971033926C929Fae645467f1C47002bfEb3'

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
