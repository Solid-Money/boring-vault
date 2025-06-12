const { ethers, upgrades } = require('hardhat')

const ownerAddress = '0x3B694d634981Ace4B64a27c48bffe19f1447779B'

async function main() {
  console.log('Deploying BridgePaymaster...')
  // Deploy BridgePaymaster
  const BridgePaymaster = await ethers.getContractFactory('BridgePaymaster')
  const paymaster = await upgrades.deployProxy(BridgePaymaster, [ownerAddress], { kind: "uups" })
  await paymaster.deployed()
  console.log("Paymaster deployed to:", await paymaster.address)
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
