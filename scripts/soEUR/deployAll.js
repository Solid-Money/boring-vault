const { ethers } = require('hardhat')
const { MAINNET_CHAIN_ID, PROFILE, requireNetwork } = require('./config')
const { deployRolesAuthority } = require('./00_deployRolesAuthority')
const { deployBoringVault } = require('./01_deployBoringVault')
const { deployManager } = require('./02_deployManagerWithMerkleVerification')
const { deployDecoder } = require('./03_deployDecoder')

// Deploys the soEUR authority, vault, manager and decoder on Ethereum. Each step records its address
// as soon as the deploy is broadcast and reuses a recorded one, so re-running this after a failure
// resumes where it stopped. The decoder on Base and the roles are separate runs; see config.js.
async function main() {
  await requireNetwork(MAINNET_CHAIN_ID)
  const [deployer] = await ethers.getSigners()
  console.log(`Profile: ${PROFILE}`)
  console.log('Deployer:', deployer.address)
  console.log('---')

  const authority = await deployRolesAuthority()
  console.log('---')
  const vault = await deployBoringVault()
  console.log('---')
  const manager = await deployManager()
  console.log('---')
  const decoder = await deployDecoder()

  console.log('\n=== Deployment Summary ===')
  console.log('RolesAuthority:', authority)
  console.log('BoringVault:   ', vault)
  console.log('Manager:       ', manager)
  console.log('Decoder:       ', decoder)
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
