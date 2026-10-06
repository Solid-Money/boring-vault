/**
 * Step 07 — read-back verification. Run after 06, and again after 08.
 *
 * Asserts the wiring that is either immutable or unrecoverable, plus the two things this
 * system's design depends on that no single contract enforces:
 *
 *   - the price provider actually answers, because a provider that reverts takes down
 *     `spend` and every view at once;
 *   - `availableToSpend` — the lens' single authorize read — does not revert. Its per-token
 *     `balanceOf` and `priceUsd` calls are unguarded, so one bad allowlisted asset declines
 *     every user's card, not just the holder's.
 *
 * Exits non-zero on any failure so it can gate a release.
 */

const { ethers, network } = require('hardhat')
const { getConfig } = require('./config')
const { FQN, loadDeployment, requireAddress, run } = require('./lib')

let failures = 0

function check(ok, label, detail = '') {
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? ` — ${detail}` : ''}`)
  if (!ok) failures++
}

function warn(label) {
  console.log(`  WARN  ${label}`)
}

const eq = (a, b) => String(a).toLowerCase() === String(b).toLowerCase()

run('07_verifyDeployment', async () => {
  const config = getConfig(network.name)
  const addresses = loadDeployment().contractAddresses || {}

  const providerAddress = requireAddress('SolidPriceProvider', '00_deploySolidPriceProvider.js')
  const authorityAddress = requireAddress('FuseRolesAuthority', '02_deployCashAuthority.js')
  const moduleAddress = requireAddress('SolidCashModule', '03_deploySolidCashModule.js')
  const lensAddress = requireAddress('SolidCashLens', '04_deploySolidCashLens.js')

  const provider = await ethers.getContractAt(FQN.provider, providerAddress)
  const authority = await ethers.getContractAt(FQN.authority, authorityAddress)
  const module = await ethers.getContractAt(FQN.module, moduleAddress)
  const lens = await ethers.getContractAt(FQN.lens, lensAddress)

  const fmt = (v) => ethers.utils.formatUnits(v, 6)

  // ── Wiring ────────────────────────────────────────────────────────────────
  console.log('Wiring:')
  check(eq(await lens.module(), moduleAddress), 'lens.module == SolidCashModule')
  check(eq(await module.priceProvider(), providerAddress), 'module.priceProvider == SolidPriceProvider')
  check(eq(await module.authority(), authorityAddress), 'module.authority == FuseRolesAuthority')
  check(
    eq(await module.settlementTreasury(), config.settlementTreasury),
    'module.settlementTreasury matches config (IMMUTABLE)'
  )

  // The treasury receives every settlement, so if it were registered the balance-delta
  // check in `_settleToken` would be trivially satisfiable. The contract blocks it at
  // registration; confirm nothing changed.
  check(
    (await module.isRegistered(config.settlementTreasury)) === false,
    'settlement treasury is not a registered Safe'
  )

  const code = await ethers.provider.getCode(await module.priceProvider())
  check(code !== '0x', 'module.priceProvider has code')

  // ── Pricing ───────────────────────────────────────────────────────────────
  console.log('\nPricing:')
  for (const feed of config.priceFeeds) {
    const [price, usable] = await provider.priceUsd(feed.token)
    check(usable, `provider prices ${feed.name}`, `${fmt(price)} USD`)
  }
  for (const token of config.module.spendTokens) {
    const [price, usable] = await module.getPriceUsd(token.address)
    check(usable, `module accepts ${token.name} price (own band applied)`, `${fmt(price)} USD`)
  }

  // ── Allowlist ─────────────────────────────────────────────────────────────
  console.log('\nAllowlist:')
  const allowed = await module.allowedTokens()
  check(
    allowed.length === config.module.spendTokens.length,
    `allowedTokens length is ${config.module.spendTokens.length}`,
    `got ${allowed.length}`
  )
  for (const token of config.module.spendTokens) {
    const cfg = await module.spendTokenConfig(token.address)
    check(cfg.allowed, `${token.name} allowlisted`)
    check(
      cfg.minPriceUsd.eq(token.minPriceUsd) && cfg.maxPriceUsd.eq(token.maxPriceUsd),
      `${token.name} band matches config`,
      `[${fmt(cfg.minPriceUsd)}, ${fmt(cfg.maxPriceUsd)}]`
    )
    check(cfg.minPriceUsd.gt(0), `${token.name} has a non-zero price floor`)
  }

  // ── Caps ──────────────────────────────────────────────────────────────────
  console.log('\nCaps:')
  const maxPerTx = await module.maxPerTxUsd()
  const maxDaily = await module.maxDailyLimitUsd()
  const maxMonthly = await module.maxMonthlyLimitUsd()
  check(maxPerTx.gt(0), 'maxPerTxUsd is set', `${fmt(maxPerTx)} USD`)
  check(maxDaily.gt(0), 'maxDailyLimitUsd is set', `${fmt(maxDaily)} USD`)
  check(maxDaily.lte(maxMonthly), 'maxDailyLimitUsd <= maxMonthlyLimitUsd')
  // The daily limit is meant to be the only cap a cardholder meets. A per-transaction cap below
  // the daily ceiling silently reintroduces a second one, and the UI no longer shows it unless it
  // binds — so catch it here rather than in a decline at the till.
  check(
    maxPerTx.gte(maxDaily),
    'maxPerTxUsd >= maxDailyLimitUsd (per-transaction cap must not bind before the daily limit)'
  )
  check(
    (await module.defaultDailyLimitUsd()).lte(maxDaily),
    'defaultDailyLimitUsd <= maxDailyLimitUsd (registerSafe would revert otherwise)'
  )
  check((await module.limitRaiseDelay()).gt(0), 'limitRaiseDelay is non-zero')
  check((await module.isPaused()) === false, 'module is not paused')

  // ── Roles ─────────────────────────────────────────────────────────────────
  console.log('\nRoles:')
  const sig = (name) => module.interface.getSighash(name)
  const { SPENDER, GUARDIAN } = config.roles

  check(
    await authority.doesRoleHaveCapability(SPENDER, moduleAddress, sig('spend')),
    'SPENDER_ROLE may call spend'
  )
  check(await authority.doesUserHaveRole(config.spender, SPENDER), 'spender key holds SPENDER_ROLE')
  check(await authority.doesUserHaveRole(config.guardian, GUARDIAN), 'guardian key holds GUARDIAN_ROLE')

  // The spender must not be able to widen its own bounds.
  for (const fn of ['setOrgCaps', 'allowSpendToken', 'setPriceProvider', 'setDustFloor', 'setDefaultLimits']) {
    check(
      !(await authority.doesRoleHaveCapability(SPENDER, moduleAddress, sig(fn))),
      `SPENDER_ROLE may NOT call ${fn}`
    )
  }
  // Both are inherited from solmate Auth and remain live; transferOwnership is requiresAuth, so
  // a role granted that selector could seize the module outright.
  for (const role of [SPENDER, GUARDIAN]) {
    for (const fn of ['transferOwnership', 'setAuthority']) {
      check(
        !(await authority.doesRoleHaveCapability(role, moduleAddress, sig(fn))),
        `role ${role} may NOT call ${fn}`
      )
    }
  }
  check(
    !(await authority.isCapabilityPublic(moduleAddress, sig('spend'))),
    'spend is not a public capability'
  )

  // ── Ownership ─────────────────────────────────────────────────────────────
  console.log('\nOwnership:')
  const [signer] = await ethers.getSigners()
  const moduleOwner = await module.owner()
  const authorityOwner = await authority.owner()

  if (eq(moduleOwner, signer.address) || eq(authorityOwner, signer.address)) {
    warn(
      `deployer still owns module=${eq(moduleOwner, signer.address)} authority=${eq(authorityOwner, signer.address)}` +
        ' — run 08_handOverOwnership.js'
    )
  }
  check(eq(moduleOwner, config.owner), 'module.owner is the configured owner', moduleOwner)
  check(eq(authorityOwner, config.owner), 'authority.owner is the configured owner', authorityOwner)

  const DEFAULT_ADMIN_ROLE = ethers.constants.HashZero
  const PRICE_ADMIN_ROLE = ethers.utils.id('PRICE_ADMIN_ROLE')
  const UPGRADER_ROLE = ethers.utils.id('UPGRADER_ROLE')

  check(await provider.hasRole(DEFAULT_ADMIN_ROLE, config.owner), 'owner holds provider DEFAULT_ADMIN_ROLE')
  check(await provider.hasRole(UPGRADER_ROLE, config.owner), 'owner holds provider UPGRADER_ROLE')
  check(
    !(await provider.hasRole(DEFAULT_ADMIN_ROLE, signer.address)) || eq(signer.address, config.owner),
    'deployer no longer holds provider DEFAULT_ADMIN_ROLE'
  )
  check(
    !(await provider.hasRole(UPGRADER_ROLE, signer.address)) || eq(signer.address, config.owner),
    'deployer no longer holds provider UPGRADER_ROLE'
  )

  // ── The authorize read ────────────────────────────────────────────────────
  // The premise of the lens is one eth_call that answers inside ~300ms and does not
  // revert. Its per-token reads are unguarded, so exercise it end to end against an
  // address with no code — the counterfactual-Safe case, which must decline cleanly
  // rather than throw.
  console.log('\nAuthorize read:')
  const probe = '0x000000000000000000000000000000000000dEaD'
  try {
    const data = await lens.availableToSpend(probe)
    check(true, 'lens.availableToSpend does not revert for a codeless address')
    check(data.moduleEnabled === false, 'codeless address reports moduleEnabled=false')
    check(data.spendableUsd.eq(0), 'codeless address reports spendableUsd=0')
    check(
      data.perTokenBreakdown.length === config.module.spendTokens.length,
      'perTokenBreakdown covers every allowlisted token'
    )
    check(data.anyPriceUnusable === false, 'no allowlisted asset is unpriceable')
    check(data.blockNumber.gt(0), 'blockNumber is populated (in-flight subtraction anchor)')

    const gas = await lens.estimateGas.availableToSpend(probe)
    console.log(`  INFO  availableToSpend gas: ${gas.toString()}`)
  } catch (error) {
    check(false, 'lens.availableToSpend reverted', error.message)
  }

  // ── Summary ───────────────────────────────────────────────────────────────
  console.log('\nAddresses:')
  for (const [name, address] of Object.entries(addresses)) {
    console.log(`  ${name.padEnd(34)} ${address}`)
  }

  if (failures > 0) {
    throw new Error(`${failures} verification check(s) failed`)
  }
  console.log('\nAll checks passed.')
})
