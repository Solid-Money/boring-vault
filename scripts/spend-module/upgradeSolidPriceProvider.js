/**
 * SolidPriceProvider UUPS upgrade.
 *
 * The provider is the upgradeable half of the split — new feed families cannot be
 * enumerated in advance, and needing a per-user re-consent migration to add one would be
 * its own risk. The module is deliberately not upgradeable.
 *
 * That makes this the sharpest trust vector in the system: an implementation that reports
 * any price turns a fixed USD debit into an arbitrary token amount. What bounds it is the
 * module's own per-token band, which is checked on every price the module receives. So the
 * post-upgrade check that matters is not "does it still deploy" but "does every allowlisted
 * token still price inside the module's band" — which is what this asserts.
 *
 * Requires UPGRADER_ROLE. With a multisig holder, run with `VALIDATE_ONLY=1` to deploy and
 * validate the implementation without switching, then submit `upgradeToAndCall` separately.
 */

const { ethers, upgrades, network } = require('hardhat')
const { getConfig } = require('./config')
const { FQN, requireAddress, saveAddress, run } = require('./lib')

run('upgradeSolidPriceProvider', async (signer) => {
  const config = getConfig(network.name)
  const proxyAddress = requireAddress('SolidPriceProvider', '00_deploySolidPriceProvider.js')

  const provider = await ethers.getContractAt(FQN.provider, proxyAddress)
  const UPGRADER_ROLE = ethers.utils.id('UPGRADER_ROLE')

  const before = await upgrades.erc1967.getImplementationAddress(proxyAddress)
  console.log(`Proxy:                  ${proxyAddress}`)
  console.log(`Current implementation: ${before}`)

  // Snapshot what the module accepts today, so the comparison after is meaningful.
  const module = await ethers.getContractAt(
    FQN.module,
    requireAddress('SolidCashModule', '03_deploySolidCashModule.js')
  )
  const snapshot = {}
  for (const token of config.module.spendTokens) {
    const [price, usable] = await module.getPriceUsd(token.address)
    snapshot[token.name] = { price, usable }
    console.log(`  before: ${token.name} = ${ethers.utils.formatUnits(price, 6)} USD (usable=${usable})`)
  }

  const Provider = await ethers.getContractFactory(FQN.provider)

  if (process.env.VALIDATE_ONLY) {
    console.log('\nVALIDATE_ONLY — deploying and validating the implementation without switching...')
    const implementation = await upgrades.prepareUpgrade(proxyAddress, Provider, { kind: 'uups' })
    console.log(`New implementation: ${implementation}`)
    console.log('\nSubmit from the UPGRADER_ROLE holder:')
    console.log(`  to:   ${proxyAddress}`)
    console.log(
      `  data: ${provider.interface.encodeFunctionData('upgradeToAndCall', [implementation, '0x'])}`
    )
    saveAddress('SolidPriceProviderPendingImplementation', implementation)
    return
  }

  if (!(await provider.hasRole(UPGRADER_ROLE, signer.address))) {
    throw new Error(
      `${signer.address} does not hold UPGRADER_ROLE on ${proxyAddress} — rerun with VALIDATE_ONLY=1 to produce calldata`
    )
  }

  console.log('\nUpgrading...')
  const upgraded = await upgrades.upgradeProxy(proxyAddress, Provider, { kind: 'uups' })
  await upgraded.deployed()

  const after = await upgrades.erc1967.getImplementationAddress(proxyAddress)
  console.log(`New implementation: ${after}`)
  saveAddress('SolidPriceProviderImplementation', after)

  // The check that matters: prices the module will actually accept, not just what the
  // provider reports.
  console.log('\nPost-upgrade prices, through the module (its own band applied):')
  let regressed = false
  for (const token of config.module.spendTokens) {
    const [price, usable] = await module.getPriceUsd(token.address)
    const was = snapshot[token.name]
    console.log(`  ${token.name} = ${ethers.utils.formatUnits(price, 6)} USD (usable=${usable})`)

    if (was.usable && !usable) {
      console.error(`  ERROR: ${token.name} was usable before the upgrade and is not now.`)
      regressed = true
    }
    if (was.usable && usable && !was.price.eq(price)) {
      // A yield-bearing share's rate moves between blocks, so a small change is expected.
      const delta = price.sub(was.price).abs().mul(10_000).div(was.price)
      console.log(`         changed by ${delta.toString()} bps`)
      if (delta.gt(100)) {
        console.error(`  ERROR: ${token.name} moved more than 1% across the upgrade — investigate before proceeding.`)
        regressed = true
      }
    }
  }

  if (regressed) {
    throw new Error('post-upgrade price regression — consider rolling back the implementation')
  }
  console.log('\nUpgrade complete, prices unchanged within tolerance.')
})
