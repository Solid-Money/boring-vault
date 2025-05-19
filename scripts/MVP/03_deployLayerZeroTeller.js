const { ethers } = require('hardhat')

const vaultAddress = '0x3e2cD0AeF639CD72Aff864b85acD5c07E2c5e3FA'
const accountantAddress = '0xC594ea2B28F5766eB66D101E0F59A958Feb9C0c5'
const wethAddress = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2'
const lzEndPointAddress = '0x1a44076050125825900e736c501f859c50fE728c'
const delegateAddress = '0xC7eDF72b6B47A5337a6d40076E1c740FCFEfd885'
const lzTokenAddress = '0x6985884C4392D348587B19cb9eAAf157F13271cd'

const authorityAddress = '0x2a9bC971033926C929Fae645467f1C47002bfEb3'

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
