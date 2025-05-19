const { ethers } = require('hardhat')

async function main() {
  const [deployer] = await ethers.getSigners()

  // Deploy BoringVault
  const BoringVault = await ethers.getContractFactory('BoringVault')
  const vault = await BoringVault.deploy(
    deployer.address,
    'Fuse WETH',
    'fWETH',
    18
  )
  await vault.deployed()

  console.log('fWETH Vault deployed at:', vault.address)
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
