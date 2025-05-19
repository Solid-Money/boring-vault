const { ethers } = require('hardhat')

const vaultTokenName = 'Fuse USDC'
const vaultTokenSymbol = 'fUSDC'
const vaultTokenDecimals = 6

const authorityAddress = '0x2a9bC971033926C929Fae645467f1C47002bfEb3'

async function main() {
  console.log('Deploying BoringVault...')
  const [deployer] = await ethers.getSigners()

  // Deploy BoringVault
  const BoringVault = await ethers.getContractFactory('BoringVault')
  const vault = await BoringVault.deploy(
    deployer.address,
    vaultTokenName,
    vaultTokenSymbol,
    vaultTokenDecimals
  )
  await vault.deployed()

  console.log(`${vaultTokenName} Vault deployed at:`, vault.address)

  // Set authority on the vault
  await vault.setAuthority(authorityAddress)
  console.log('Vault authority updated')
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
