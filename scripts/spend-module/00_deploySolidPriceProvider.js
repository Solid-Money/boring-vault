/**
 * Step 00 — SolidPriceProvider behind a UUPS proxy.
 *
 * The provider is deployed with the *deployer* as admin so steps 01 can configure feeds
 * without a multisig round-trip. Step 08 moves DEFAULT_ADMIN_ROLE, PRICE_ADMIN_ROLE and
 * UPGRADER_ROLE to the real holders and renounces the deployer's, and step 07 fails the
 * deployment if that has not happened. Do not stop before step 08.
 */

const { ethers, upgrades, network } = require('hardhat')
const { getConfig } = require('./config')
const { FQN, saveAddress, run } = require('./lib')

run('00_deploySolidPriceProvider', async (signer) => {
  getConfig(network.name) // validate the network is configured before spending gas

  const Provider = await ethers.getContractFactory(FQN.provider)

  console.log('Deploying SolidPriceProvider (UUPS proxy)...')
  console.log(`  bootstrap admin: ${signer.address} (handed over in step 08)`)

  const provider = await upgrades.deployProxy(Provider, [signer.address], { kind: 'uups' })
  await provider.deployed()

  const implementation = await upgrades.erc1967.getImplementationAddress(provider.address)

  console.log(`\nSolidPriceProvider proxy:          ${provider.address}`)
  console.log(`SolidPriceProvider implementation: ${implementation}`)

  saveAddress('SolidPriceProvider', provider.address)
  saveAddress('SolidPriceProviderImplementation', implementation)
})
