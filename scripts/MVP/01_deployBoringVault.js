const { ethers } = require('hardhat')

const vaultTokenName = 'Solid USD'
const vaultTokenSymbol = 'soUSD'
const vaultTokenDecimals = 6

const authorityAddress = '0x9FcD641048F06d070A50a70EE4C941deCBCF7CfB'

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
