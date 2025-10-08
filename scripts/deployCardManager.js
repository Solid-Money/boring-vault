const { ethers, upgrades } = require('hardhat')

const ownerAddress = '0x3B694d634981Ace4B64a27c48bffe19f1447779B'
const vaultAddress = '0x75333830E7014e909535389a6E5b0C02aA62ca27'
const accountantAddress = '0x47A5e832E1178726dd13AdD762774A704878AD98'
const isWhitelistEnabled = false

async function main() {
  console.log('Deploying CardManager...')
  console.log('Owner address:', ownerAddress)
  
  // Deploy CardManager
  const CardManager = await ethers.getContractFactory('src/fuse/CardManager/CardDepositManager.sol:CardDepositManager')
  console.log('Contract factory created')

  const cardManager = await CardManager.deploy(
    ownerAddress,
    vaultAddress,
    accountantAddress,
    isWhitelistEnabled
  )
  await cardManager.deployed()

  console.log(`CardManager deployed at:`, cardManager.address)
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })