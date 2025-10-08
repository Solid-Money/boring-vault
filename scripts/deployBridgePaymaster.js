const { ethers, upgrades } = require('hardhat')

const ownerAddress = '0x3B694d634981Ace4B64a27c48bffe19f1447779B'

async function main() {
  console.log('Deploying BridgePaymaster...')
  console.log('Owner address:', ownerAddress)
  
  // Deploy BridgePaymaster
  const BridgePaymaster = await ethers.getContractFactory('src/fuse/BridgePaymaster.sol:BridgePaymaster')
  console.log('Contract factory created')
  
  try {
    console.log('Starting proxy deployment...')
    const paymaster = await upgrades.deployProxy(
      BridgePaymaster, 
      [ownerAddress], 
      { 
        kind: "uups",
      }
    )
    console.log('Proxy deployment transaction sent')
    
    await paymaster.deployed()
    console.log("Paymaster deployed to:", await paymaster.address)
    
    // Verify owner was set correctly
    const owner = await paymaster.owner()
    console.log("Owner set to:", owner)
  } catch (error) {
    console.error('Deployment failed:', error)
    if (error.transaction) {
      console.error('Transaction hash:', error.transaction.hash)
      console.error('Transaction data:', error.transaction.data)
    }
    throw error
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })