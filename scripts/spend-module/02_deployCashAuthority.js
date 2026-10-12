/**
 * Step 02 — the FuseRolesAuthority governing the spend module.
 *
 * A dedicated authority rather than the vault's. `requiresAuth` on SolidCashModule is
 * uniform across `spend`, the guardian functions and every `set*`, so the whole
 * SPENDER/GUARDIAN/owner separation the module documents lives in *this* contract's
 * capability table and nowhere else. Sharing the vault's authority would put that table
 * under the vault owner's control and give whoever administers it a path to the spend role.
 *
 * Set `existingAuthority` in config.js to skip this and reuse one deliberately.
 *
 * Deployed with the deployer as owner so step 05 can set capabilities; step 08 hands it to
 * the real owner.
 */

const { ethers, network } = require('hardhat')
const { getConfig } = require('./config')
const { FQN, saveAddress, requireHasCode, run } = require('./lib')

run('02_deployCashAuthority', async (signer) => {
  const config = getConfig(network.name)

  if (config.existingAuthority) {
    await requireHasCode(config.existingAuthority, 'existing authority')
    console.log(`Reusing configured authority: ${config.existingAuthority}`)
    saveAddress('FuseRolesAuthority', config.existingAuthority)
    return
  }

  console.log('Deploying FuseRolesAuthority for the spend module...')
  console.log(`  bootstrap owner: ${signer.address} (handed over in step 08)`)

  const Authority = await ethers.getContractFactory(FQN.authority)
  const authority = await Authority.deploy(signer.address, ethers.constants.AddressZero)
  await authority.deployed()

  console.log(`\nFuseRolesAuthority: ${authority.address}`)
  saveAddress('FuseRolesAuthority', authority.address)
})
