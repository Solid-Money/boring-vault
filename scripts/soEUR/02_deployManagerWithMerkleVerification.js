const { ethers } = require('hardhat')
const {
  MAINNET_CHAIN_ID,
  PROFILE,
  balancerVault,
  requireNetwork,
  requireDeployed,
  deployOrResume,
  ensureAuthority,
} = require('./config')

// Ethereum soEUR ManagerWithMerkleVerification. Its manage root stays empty until the owner sets the
// strategist's root.
async function deployManager() {
  const chainId = await requireNetwork(MAINNET_CHAIN_ID)
  const authority = requireDeployed(chainId, 'RolesAuthority')
  const vault = requireDeployed(chainId, 'BoringVault')
  const [deployer] = await ethers.getSigners()

  console.log(`Deploying soEUR (${PROFILE}) ManagerWithMerkleVerification...`)
  const manager = await deployOrResume(chainId, 'ManagerWithMerkleVerification', 'Manager', async () => [
    deployer.address,
    vault,
    balancerVault,
  ])
  await ensureAuthority(manager, authority)
  return manager.address
}

if (require.main === module) {
  deployManager()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error)
      process.exit(1)
    })
}

module.exports = { deployManager }
