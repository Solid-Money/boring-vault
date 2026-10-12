const { ethers } = require('hardhat')

const vaultAddress = '0xF88Ce04C3ef43F3501fA99eE06a5473f5ef33BED'
const payoutAddress = '0x3B694d634981Ace4B64a27c48bffe19f1447779B'
const authorityAddress = '0x2B7e98a2FC5f9B61adCd6D19049A559922A788B4'
const baseTokenAddress = '0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590'

const startingExchangeRate = 1e18.toString()
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
