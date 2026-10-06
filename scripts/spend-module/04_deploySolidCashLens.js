/**
 * Step 04 — SolidCashLens.
 *
 * Holds no state and no authority; it reads the module through the module's own view
 * functions. Its `module` is immutable, so a lens can never drift onto other logic — which
 * also means a module redeploy needs a new lens.
 */

const { ethers, network } = require('hardhat')
const { getConfig } = require('./config')
const { FQN, saveAddress, requireAddress, requireHasCode, run } = require('./lib')

run('04_deploySolidCashLens', async () => {
  getConfig(network.name)

  const moduleAddress = requireAddress('SolidCashModule', '03_deploySolidCashModule.js')
  await requireHasCode(moduleAddress, 'SolidCashModule')

  console.log('Deploying SolidCashLens...')
  console.log(`  module: ${moduleAddress}   <-- IMMUTABLE`)

  const Lens = await ethers.getContractFactory(FQN.lens)
  const lens = await Lens.deploy(moduleAddress)
  await lens.deployed()

  console.log(`\nSolidCashLens: ${lens.address}`)
  saveAddress('SolidCashLens', lens.address)
})
