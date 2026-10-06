/**
 * Step 06 — module caps, limits and token allowlist.
 *
 * Order matters in one place: the org ceilings must be set before `setDefaultLimits` is
 * meaningful, because `registerSafe` checks a Safe's chosen (or defaulted) caps against the
 * live ceilings. Defaults above the ceilings would make every registration revert.
 *
 * Everything here is live and immediate. Lowering `maxDailyLimitUsd` later applies to
 * already-registered Safes on the next read, and tightening a token's price band makes that
 * token unspendable without pausing the module — those are the intended runtime controls.
 */

const { ethers, network } = require('hardhat')
const { getConfig } = require('./config')
const { FQN, requireAddress, requireHasCode, ownerCall, run } = require('./lib')

run('06_configureCashModule', async () => {
  const config = getConfig(network.name)
  const m = config.module

  const moduleAddress = requireAddress('SolidCashModule', '03_deploySolidCashModule.js')
  const module = await ethers.getContractAt(FQN.module, moduleAddress)
  const owner = await module.owner()

  const fmt = (v) => ethers.utils.formatUnits(v, 6)

  // Contract-enforced, but failing here costs nothing and reads better than a revert.
  if (m.maxDailyLimitUsd.gt(m.maxMonthlyLimitUsd)) {
    throw new Error('maxDailyLimitUsd must not exceed maxMonthlyLimitUsd')
  }
  if (m.defaultDailyLimitUsd.gt(m.defaultMonthlyLimitUsd)) {
    throw new Error('defaultDailyLimitUsd must not exceed defaultMonthlyLimitUsd')
  }
  // Not contract-enforced: a default above the ceiling makes every `registerSafe` revert.
  if (m.defaultDailyLimitUsd.gt(m.maxDailyLimitUsd)) {
    throw new Error('defaultDailyLimitUsd exceeds maxDailyLimitUsd — registerSafe would always revert')
  }
  if (m.defaultMonthlyLimitUsd.gt(m.maxMonthlyLimitUsd)) {
    throw new Error('defaultMonthlyLimitUsd exceeds maxMonthlyLimitUsd — registerSafe would always revert')
  }

  console.log('Org caps and limits:')
  await ownerCall(
    `setOrgCaps(perTx=${fmt(m.maxPerTxUsd)}, daily=${fmt(m.maxDailyLimitUsd)}, monthly=${fmt(m.maxMonthlyLimitUsd)})`,
    module,
    'setOrgCaps',
    [m.maxPerTxUsd, m.maxDailyLimitUsd, m.maxMonthlyLimitUsd],
    owner
  )
  await ownerCall(
    `setDefaultLimits(daily=${fmt(m.defaultDailyLimitUsd)}, monthly=${fmt(m.defaultMonthlyLimitUsd)})`,
    module,
    'setDefaultLimits',
    [m.defaultDailyLimitUsd, m.defaultMonthlyLimitUsd],
    owner
  )
  await ownerCall(
    `setLimitRaiseDelay(${m.limitRaiseDelay}s)`,
    module,
    'setLimitRaiseDelay',
    [m.limitRaiseDelay],
    owner
  )
  await ownerCall(`setDustFloor(${fmt(m.dustFloorUsd)})`, module, 'setDustFloor', [m.dustFloorUsd], owner)

  console.log('\nToken allowlist:')
  for (const token of m.spendTokens) {
    await requireHasCode(token.address, `${token.name} token`)

    // `allowSpendToken` reads decimals from the token but never cross-checks the price
    // provider's cached `tokenDecimals` for it, despite the shared error name. A mismatch
    // would misprice every settlement of this asset, so check it here.
    const providerAddress = await module.priceProvider()
    const provider = await ethers.getContractAt(FQN.provider, providerAddress)
    const feed = await provider.getConfig(token.address)

    if (Number(feed.kind) === 0) {
      throw new Error(`${token.name} has no feed configured on the price provider — run step 01`)
    }

    const asToken = new ethers.Contract(
      token.address,
      ['function decimals() view returns (uint8)'],
      ethers.provider
    )
    const onChainDecimals = await asToken.decimals()

    if (Number(feed.tokenDecimals) !== Number(onChainDecimals)) {
      throw new Error(
        `${token.name} decimals mismatch: provider config says ${feed.tokenDecimals}, token reports ${onChainDecimals}`
      )
    }

    // The module's band must not be looser than the provider's, or the module's independent
    // check stops being the backstop it exists to be.
    if (token.minPriceUsd.lt(feed.minPriceUsd) || token.maxPriceUsd.gt(feed.maxPriceUsd)) {
      console.warn(
        `  WARNING: ${token.name}'s module band [${fmt(token.minPriceUsd)}, ${fmt(token.maxPriceUsd)}] is ` +
          `wider than the provider's [${fmt(feed.minPriceUsd)}, ${fmt(feed.maxPriceUsd)}]. The module band is ` +
          `the defence against a hostile provider upgrade — it should be at least as tight.`
      )
    }

    await ownerCall(
      `allowSpendToken(${token.name}, haircut=${token.haircutBps}bps, band=[${fmt(token.minPriceUsd)}, ${fmt(token.maxPriceUsd)}])`,
      module,
      'allowSpendToken',
      [token.address, token.haircutBps, token.minPriceUsd, token.maxPriceUsd],
      owner
    )
  }
})
