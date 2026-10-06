/**
 * Step 08 — hand every privileged key to its production holder. Mandatory.
 *
 * Steps 00-06 deploy with the deployer as owner/admin so configuration does not need a
 * multisig round-trip per transaction. Until this runs, an EOA can raise the org ceilings
 * and allowlist tokens on live user funds.
 *
 * Ordering is deliberate and not reorderable:
 *   1. grant the provider's roles to the new holders
 *   2. renounce the deployer's provider roles  (grant before renounce, or the proxy is
 *      permanently unadministrable and un-upgradeable)
 *   3. transfer the authority's owner
 *   4. transfer the module's owner — last, because it is the one that gates re-doing any of
 *      the above through the module
 *
 * Run 07_verifyDeployment.js afterwards; it fails if any of this is incomplete.
 */

const { ethers, network } = require('hardhat')
const { getConfig } = require('./config')
const { FQN, requireAddress, requireConfigured, run } = require('./lib')

const eq = (a, b) => String(a).toLowerCase() === String(b).toLowerCase()

run('08_handOverOwnership', async (signer) => {
  const config = getConfig(network.name)
  const owner = requireConfigured(config.owner, 'owner')

  if (eq(owner, signer.address)) {
    console.log('Configured owner is the deployer — nothing to hand over.')
    console.log('For production this should be the timelocked multisig, not an EOA.')
    return
  }

  const provider = await ethers.getContractAt(
    FQN.provider,
    requireAddress('SolidPriceProvider', '00_deploySolidPriceProvider.js')
  )
  const authority = await ethers.getContractAt(
    FQN.authority,
    requireAddress('FuseRolesAuthority', '02_deployCashAuthority.js')
  )
  const module = await ethers.getContractAt(
    FQN.module,
    requireAddress('SolidCashModule', '03_deploySolidCashModule.js')
  )

  const DEFAULT_ADMIN_ROLE = ethers.constants.HashZero
  const PRICE_ADMIN_ROLE = ethers.utils.id('PRICE_ADMIN_ROLE')
  const UPGRADER_ROLE = ethers.utils.id('UPGRADER_ROLE')

  // PRICE_ADMIN is day-to-day feed configuration; UPGRADER can replace the implementation
  // over live user funds. The contract's own docs call for these to be different keys.
  // `priceAdmin` falls back to the owner when unset, which is safe but means one key does
  // both — set it explicitly for production.
  const priceAdmin = config.priceAdmin || owner
  if (eq(priceAdmin, owner)) {
    console.warn(
      'WARNING: PRICE_ADMIN_ROLE and UPGRADER_ROLE will both sit on the owner.\n' +
        '         Set config.priceAdmin to split day-to-day feed configuration from upgrade authority.\n'
    )
  }

  const send = async (label, promise) => {
    const tx = await promise
    await tx.wait()
    console.log(`  ${label} — tx ${tx.hash}`)
  }

  // 1. Grant, before renouncing anything.
  console.log('Price provider — granting roles:')
  if (!(await provider.hasRole(DEFAULT_ADMIN_ROLE, owner))) {
    await send(`grant DEFAULT_ADMIN_ROLE to ${owner}`, provider.grantRole(DEFAULT_ADMIN_ROLE, owner))
  }
  if (!(await provider.hasRole(UPGRADER_ROLE, owner))) {
    await send(`grant UPGRADER_ROLE to ${owner}`, provider.grantRole(UPGRADER_ROLE, owner))
  }
  if (!(await provider.hasRole(PRICE_ADMIN_ROLE, priceAdmin))) {
    await send(`grant PRICE_ADMIN_ROLE to ${priceAdmin}`, provider.grantRole(PRICE_ADMIN_ROLE, priceAdmin))
  }

  // Refuse to renounce into a bricked proxy.
  if (!(await provider.hasRole(DEFAULT_ADMIN_ROLE, owner))) {
    throw new Error('refusing to renounce: new owner does not hold DEFAULT_ADMIN_ROLE')
  }

  // 2. Renounce the deployer's. `renounceRole` only accepts the caller's own account.
  console.log('\nPrice provider — renouncing deployer roles:')
  for (const [name, role] of [
    ['PRICE_ADMIN_ROLE', PRICE_ADMIN_ROLE],
    ['UPGRADER_ROLE', UPGRADER_ROLE],
    ['DEFAULT_ADMIN_ROLE', DEFAULT_ADMIN_ROLE],
  ]) {
    if (await provider.hasRole(role, signer.address)) {
      await send(`renounce ${name}`, provider.renounceRole(role, signer.address))
    }
  }

  // 3. Authority.
  console.log('\nAuthority:')
  const authorityOwner = await authority.owner()
  if (eq(authorityOwner, signer.address)) {
    await send(`transferOwnership(${owner})`, authority.transferOwnership(owner))
  } else {
    console.log(`  already owned by ${authorityOwner}`)
  }

  // 4. Module last.
  console.log('\nModule:')
  const moduleOwner = await module.owner()
  if (eq(moduleOwner, signer.address)) {
    await send(`transferOwnership(${owner})`, module.transferOwnership(owner))
  } else {
    console.log(`  already owned by ${moduleOwner}`)
  }

  console.log('\nHandover complete. Run 07_verifyDeployment.js to confirm.')
})
