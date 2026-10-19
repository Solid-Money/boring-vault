const { ethers } = require('hardhat')
const { MAINNET_CHAIN_ID, PROFILE, requireNetwork, deployOrResume } = require('./config')

// RolesAuthority for the Ethereum soEUR vault and manager. The deployer owns it until
// 04_configureRoles.js has set the roles and handed it to the profile's owner.
async function deployRolesAuthority() {
  const chainId = await requireNetwork(MAINNET_CHAIN_ID)
  const [deployer] = await ethers.getSigners()
  console.log(`Deploying soEUR (${PROFILE}) RolesAuthority...`)
  const authority = await deployOrResume(chainId, 'RolesAuthority', 'RolesAuthority', async () => [
    deployer.address,
    ethers.constants.AddressZero,
  ])
  return authority.address
}

if (require.main === module) {
  deployRolesAuthority()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error)
      process.exit(1)
    })
}

module.exports = { deployRolesAuthority }
