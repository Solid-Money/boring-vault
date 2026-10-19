const { ethers } = require('hardhat')
const {
  MAINNET_CHAIN_ID,
  PROFILE,
  vaultToken,
  requireNetwork,
  requireDeployed,
  deployOrResume,
  ensureAuthority,
} = require('./config')

// Ethereum soEUR BoringVault. It only holds EURC bridged from the Base vault; no shares are minted
// here, so it gets no teller, accountant or queue.
async function deployBoringVault() {
  const chainId = await requireNetwork(MAINNET_CHAIN_ID)
  const authority = requireDeployed(chainId, 'RolesAuthority')
  const [deployer] = await ethers.getSigners()

  console.log(`Deploying soEUR (${PROFILE}) BoringVault...`)
  const vault = await deployOrResume(chainId, 'BoringVault', 'BoringVault', async () => [
    deployer.address,
    vaultToken.name,
    vaultToken.symbol,
    vaultToken.decimals,
  ])
  await ensureAuthority(vault, authority)
  return vault.address
}

if (require.main === module) {
  deployBoringVault()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error)
      process.exit(1)
    })
}

module.exports = { deployBoringVault }
