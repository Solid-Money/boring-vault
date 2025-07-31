const { ethers } = require('hardhat')

const vaultAddress = '0x75333830E7014e909535389a6E5b0C02aA62ca27'
const accountantAddress = '0x47A5e832E1178726dd13AdD762774A704878AD98'
const wethAddress = '0x0BE9e53fd7EDaC9F859882AfdDa116645287C629'
const lzEndPointAddress = '0x1a44076050125825900e736c501f859c50fE728c'
const delegateAddress = '0x03709784c96aeaAa9Dd38Df14A23e996681b2C66'
const lzTokenAddress = '0x0000000000000000000000000000000000000000'

const authorityAddress = '0x9ba8969613F3Ea41dE962054A8Faa50ae54F5956'

async function main() {
  console.log('Deploying LayerZero Teller...')
  const [deployer] = await ethers.getSigners()
  console.log('Deployer address:', deployer.address)

  // Deploy LayerZero Teller
  const Teller = await ethers.getContractFactory('LayerZeroTeller')

  const teller = await Teller.deploy(
    deployer.address,
    vaultAddress,
    accountantAddress,
    wethAddress,
    lzEndPointAddress,
    delegateAddress,
    lzTokenAddress,
  )
  await teller.deployed()

  console.log(`Teller deployed at:`, teller.address)

  // Set authority on the teller
  await teller.setAuthority(authorityAddress)
  console.log('Teller authority updated')
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
