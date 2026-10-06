const { ethers } = require('hardhat')

const vaultTokenName = 'Fuse ETH'
const vaultTokenSymbol = 'fETH'
const vaultTokenDecimals = 18

const authorityAddress = '0x2B7e98a2FC5f9B61adCd6D19049A559922A788B4'

async function main() {
  console.log('Deploying BoringVault...')
  const [deployer] = await ethers.getSigners()

  // Deploy BoringVault
  const BoringVault = await ethers.getContractFactory('src/base/BoringVault.sol:BoringVault')
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
