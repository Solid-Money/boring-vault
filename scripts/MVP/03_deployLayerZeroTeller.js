const { ethers } = require('hardhat')

const vaultAddress = '0xF88Ce04C3ef43F3501fA99eE06a5473f5ef33BED'
const accountantAddress = '0x7EFD6391537518dC2A8260ff535439704AD6a111'
const wethAddress = '0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590'
const lzEndPointAddress = '0x1a44076050125825900e736c501f859c50fE728c'
const delegateAddress = '0x3B694d634981Ace4B64a27c48bffe19f1447779B'
const lzTokenAddress = '0x0000000000000000000000000000000000000000'
const authorityAddress = '0x2B7e98a2FC5f9B61adCd6D19049A559922A788B4'

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
