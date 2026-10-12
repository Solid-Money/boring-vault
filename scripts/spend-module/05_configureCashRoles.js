/**
 * Step 05 — role capabilities on the spend module's authority.
 *
 * This table is the entire enforcement of the role separation the module documents.
 * `requiresAuth` is uniform across `spend`, `pause`/`unpause`/`setSafePaused` and every
 * `set*` function, so the module itself does not distinguish them — only the grants below do.
 *
 * Two consequences worth being deliberate about:
 *
 *   - SPENDER_ROLE gets exactly `spend`. Nothing else. A spender that could also call
 *     `setOrgCaps` or `allowSpendToken` would be able to widen its own bounds.
 *   - No role is granted `transferOwnership` or `setAuthority`. Both are inherited from
 *     solmate's `Auth` and remain callable, `transferOwnership` under `requiresAuth` — so any
 *     role granted that selector could seize the module. They stay owner-only.
 *
 * Selectors are derived from the compiled ABI rather than hardcoded, so a signature change
 * cannot silently grant a role over the wrong function.
 */

const { ethers, network } = require('hardhat')
const { getConfig } = require('./config')
const { FQN, requireAddress, requireConfigured, ownerCall, run } = require('./lib')

run('05_configureCashRoles', async () => {
  const config = getConfig(network.name)

  const authorityAddress = requireAddress('FuseRolesAuthority', '02_deployCashAuthority.js')
  const moduleAddress = requireAddress('SolidCashModule', '03_deploySolidCashModule.js')

  const spender = requireConfigured(config.spender, 'spender')
  const guardian = requireConfigured(config.guardian, 'guardian')

  const authority = await ethers.getContractAt(FQN.authority, authorityAddress)
  const module = await ethers.getContractAt(FQN.module, moduleAddress)
  const authorityOwner = await authority.owner()

  const sig = (name) => module.interface.getSighash(name)

  const { SPENDER, GUARDIAN } = config.roles

  const capabilities = [
    { role: SPENDER, roleName: 'SPENDER', fn: 'spend' },
    { role: GUARDIAN, roleName: 'GUARDIAN', fn: 'pause' },
    { role: GUARDIAN, roleName: 'GUARDIAN', fn: 'unpause' },
    { role: GUARDIAN, roleName: 'GUARDIAN', fn: 'setSafePaused' },
  ]

  console.log('Role capabilities:')
  for (const cap of capabilities) {
    await ownerCall(
      `setRoleCapability(${cap.roleName}, module.${cap.fn}) [${sig(cap.fn)}]`,
      authority,
      'setRoleCapability',
      [cap.role, moduleAddress, sig(cap.fn), true],
      authorityOwner
    )
  }

  console.log('\nRole assignments:')
  await ownerCall(
    `setUserRole(SPENDER, ${spender})`,
    authority,
    'setUserRole',
    [spender, SPENDER, true],
    authorityOwner
  )
  await ownerCall(
    `setUserRole(GUARDIAN, ${guardian})`,
    authority,
    'setUserRole',
    [guardian, GUARDIAN, true],
    authorityOwner
  )

  console.log(
    '\nNote: every `set*` on the module stays owner-only by omission — no role is granted a\n' +
      'configuration selector, and none is granted transferOwnership/setAuthority.'
  )
})
