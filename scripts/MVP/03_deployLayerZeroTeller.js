const { ethers } = require('hardhat')

const vaultAddress = '0xBd37f551CEb90369dcf1e46Ddb60937B0AdEE107'
const accountantAddress = '0x40B8cDB606A72861e0e7831f63DFbA7D5511c14e'
const wethAddress = '0x4200000000000000000000000000000000000006'
const lzEndPointAddress = '0x1a44076050125825900e736c501f859c50fE728c'
const delegateAddress = '0x3B694d634981Ace4B64a27c48bffe19f1447779B'
const lzTokenAddress = '0x6985884C4392D348587B19cb9eAAf157F13271cd'
const authorityAddress = '0x4F85400195a87dFD92bCa1922068609998bccAEe'

async function main() {
  console.log('Deploying LayerZero Teller...')
  const [deployer] = await ethers.getSigners()
  console.log('Deployer address:', deployer.address)

  // Deploy LayerZero Teller
  const Teller = await ethers.getContractFactory('src/base/Roles/CrossChain/Bridges/LayerZero/LayerZeroTeller.sol:LayerZeroTeller')

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
