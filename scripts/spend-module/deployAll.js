/**
 * Runs the whole spend-module deployment in order, in one process.
 *
 * Each step is idempotent-ish but not transactional: a failure part-way leaves the earlier
 * steps deployed and recorded in deployments/addresses/<Network>/SpendModule.json. Rerun
 * the individual step that failed rather than this script, or the already-deployed
 * contracts will be deployed a second time.
 *
 * Steps 00-06 need the deployer to be the owner/admin. Step 08 hands everything over.
 */

const { execFileSync } = require('child_process')
const { network } = require('hardhat')
const { getConfig } = require('./config')

const STEPS = [
  '00_deploySolidPriceProvider',
  '01_configurePriceFeeds',
  '02_deployCashAuthority',
  '03_deploySolidCashModule',
  '04_deploySolidCashLens',
  '05_configureCashRoles',
  '06_configureCashModule',
  '07_verifyDeployment',
  '08_handOverOwnership',
]

async function main() {
  // Fail before any gas is spent if the config is incomplete.
  const config = getConfig(network.name)
  for (const field of ['owner', 'spender', 'guardian', 'settlementTreasury']) {
    if (!config[field] || /^0x0{40}$/i.test(config[field])) {
      throw new Error(`config.${field} is unset — fill scripts/spend-module/config.js first`)
    }
  }

  console.log(`Deploying the Solid card spend module to ${network.name}.`)
  console.log(`settlementTreasury: ${config.settlementTreasury} (IMMUTABLE once step 03 runs)\n`)

  for (const step of STEPS) {
    // Each step calls process.exit on completion, so run it out of process.
    console.log(`\n>>> ${step}`)
    execFileSync(
      'npx',
      ['hardhat', 'run', `scripts/spend-module/${step}.js`, '--network', network.name],
      { stdio: 'inherit' }
    )
  }

  console.log('\nDone. Re-run 07_verifyDeployment.js to confirm the post-handover state.')
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
