/**
 * Step 03 — SolidCashModule.
 *
 * Non-upgradeable, and two constructor arguments are immutable for its whole life:
 *
 *   settlementTreasury — the only address `spend` can ever send to. Wrong value here means
 *     a redeploy and a re-consent migration for every registered Safe, because migration
 *     requires each Safe owner to enable the new module.
 *   owner — bootstrapped to the deployer so steps 05/06 can configure, handed over in 08.
 *
 * Guards applied before deploying, because none of them are recoverable afterwards:
 *   - the treasury is not the zero address and is not one of the tokens
 *   - the price provider has code and answers `priceUsd` (the module only checks non-zero,
 *     and a provider that cannot answer bricks both `spend` and every view)
 */

const { ethers, network } = require('hardhat')
const { getConfig } = require('./config')
const { FQN, saveAddress, requireAddress, requireConfigured, requireHasCode, run } = require('./lib')

run('03_deploySolidCashModule', async (signer) => {
  const config = getConfig(network.name)

  const providerAddress = requireAddress('SolidPriceProvider', '00_deploySolidPriceProvider.js')
  const authorityAddress = requireAddress('FuseRolesAuthority', '02_deployCashAuthority.js')
  const treasury = requireConfigured(config.settlementTreasury, 'settlementTreasury')

  await requireHasCode(providerAddress, 'SolidPriceProvider')
  await requireHasCode(authorityAddress, 'FuseRolesAuthority')

  // The provider address is immutable in practice: `setPriceProvider` only checks for the
  // zero address, so an address that cannot answer `priceUsd` reverts every spend and every
  // lens read until the owner corrects it. Prove it answers before wiring it in.
  const provider = await ethers.getContractAt(FQN.provider, providerAddress)
  for (const token of config.module.spendTokens) {
    const [price, usable] = await provider.priceUsd(token.address)
    if (!usable) {
      throw new Error(
        `price provider reports ${token.name} (${token.address}) as unusable — run 01_configurePriceFeeds.js first`
      )
    }
    console.log(`  provider prices ${token.name} at ${ethers.utils.formatUnits(price, 6)} USD`)
  }

  // A treasury that is also a spend token, or the module itself, would make the
  // balance-delta settlement check meaningless.
  for (const token of config.module.spendTokens) {
    if (token.address.toLowerCase() === treasury.toLowerCase()) {
      throw new Error('settlementTreasury must not be one of the spend tokens')
    }
  }

  console.log('\nDeploying SolidCashModule...')
  console.log(`  owner (bootstrap):  ${signer.address}`)
  console.log(`  authority:          ${authorityAddress}`)
  console.log(`  settlementTreasury: ${treasury}   <-- IMMUTABLE`)
  console.log(`  priceProvider:      ${providerAddress}`)

  const Module = await ethers.getContractFactory(FQN.module)
  const module = await Module.deploy(signer.address, authorityAddress, treasury, providerAddress)
  await module.deployed()

  console.log(`\nSolidCashModule: ${module.address}`)
  saveAddress('SolidCashModule', module.address)
  saveAddress('SettlementTreasury', treasury)
})
