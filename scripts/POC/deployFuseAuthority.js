const { ethers } = require('hardhat')

async function main() {
  const vaultAddress = '0x445395FB71f2Dc65F80F947995af271c25807d88'
  const BoringVault = await ethers.getContractFactory('BoringVault')
  const vault = await BoringVault.attach(vaultAddress)
  console.log('Connected to BoringVault at:', vault.address)

  // Deploy SimpleAuthority
  const SimpleAuthority = await ethers.getContractFactory('SimpleAuthority')
  const authority = await SimpleAuthority.deploy()
  await authority.deployed()
  console.log('SimpleAuthority deployed at:', authority.address)

  // Address to authorize
  const addressToAuthorize = '0x70D1c611788aFF8228b5d845A5Dc95927022cF7c'
  console.log('Authorizing address:', addressToAuthorize)

  // Compute selector for manage function
  const manageSelector = ethers.utils
    .id('manage(address,bytes,uint256)')
    .slice(0, 10)

  // Grant permission to addressToAuthorize to call vault.manage
  await authority.setPermission(
    addressToAuthorize,
    vault.address,
    manageSelector,
    true
  )
  console.log('Permission granted to authorized address')

  // Set authority on the vault
  await vault.setAuthority(authority.address)
  console.log('Vault authority updated')
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
