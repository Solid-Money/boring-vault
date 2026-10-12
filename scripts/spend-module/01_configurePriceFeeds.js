/**
 * Step 01 — per-token feeds on the price provider.
 *
 * Feeds are applied in the order given in config.js. That order is load-bearing: a
 * VEDA_ACCOUNTANT feed reverts with `BaseAssetNotConfigured` unless its base asset already
 * has a feed, so bases (USDC) must precede composed tokens (soUSD).
 *
 * `setTokenConfig` already validates the relationships that would otherwise silently
 * misprice an asset — `accountant.vault() == token`, `accountant.base() == baseAsset`, and
 * both decimals fields against the tokens themselves — so a misconfiguration here reverts
 * rather than reaching production. The read-back at the end is the check it cannot do:
 * that the composed price is actually usable right now.
 */

const { ethers, network } = require('hardhat')
const { getConfig } = require('./config')
const { FQN, requireAddress, requireHasCode, ownerCall, run } = require('./lib')

run('01_configurePriceFeeds', async () => {
  const config = getConfig(network.name)
  const providerAddress = requireAddress('SolidPriceProvider', '00_deploySolidPriceProvider.js')

  await requireHasCode(providerAddress, 'SolidPriceProvider')
  const provider = await ethers.getContractAt(FQN.provider, providerAddress)

  // Feed configuration is PRICE_ADMIN_ROLE-gated, not owner-gated. Resolve once whether this
  // signer may send; if not, the calls are queued as calldata for whoever holds the role.
  const PRICE_ADMIN_ROLE = ethers.utils.id('PRICE_ADMIN_ROLE')
  const [signer] = await ethers.getSigners()
  const canSend = await provider.hasRole(PRICE_ADMIN_ROLE, signer.address)
  const sender = canSend ? signer.address : config.owner

  if (!canSend) {
    console.log('Signer does not hold PRICE_ADMIN_ROLE — queueing calldata instead of sending.\n')
  }

  for (const feed of config.priceFeeds) {
    await requireHasCode(feed.token, `${feed.name} token`)
    if (feed.config.source !== ethers.constants.AddressZero) {
      await requireHasCode(feed.config.source, `${feed.name} accountant`)
    }

    console.log(`Configuring ${feed.name} (${feed.token}) as kind ${feed.config.kind}...`)

    await ownerCall(`setTokenConfig(${feed.name})`, provider, 'setTokenConfig', [feed.token, feed.config], sender)
  }

  // Read back through the same path the module will use.
  console.log('\nPrices as the provider now reports them:')
  for (const feed of config.priceFeeds) {
    const [price, usable] = await provider.priceUsd(feed.token)
    console.log(
      `  ${feed.name.padEnd(6)} usable=${usable}  price=${ethers.utils.formatUnits(price, 6)} USD`
    )
    if (!usable) {
      console.warn(
        `  WARNING: ${feed.name} is not usable. A token allowlisted in the module while its ` +
          `feed is unusable contributes 0 to quoted spending power and cannot be spent.`
      )
    }
  }
})
