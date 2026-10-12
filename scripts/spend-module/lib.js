/**
 * Shared plumbing for the spend-module deployment scripts.
 *
 * Two things live here rather than being repeated in each step:
 *
 *   1. A deployment record on disk. The chain is eight steps long and later steps need
 *      earlier addresses; hand-editing a constant at the top of each file (the older
 *      convention in `scripts/MVP/`) is one typo away from pointing the module at the
 *      wrong price provider, which is not a mistake this system recovers from cheaply.
 *
 *   2. Owner-aware sends. Configuration is owner-gated, and in production the owner is a
 *      timelocked multisig that cannot run a Hardhat script. When the signer is not the
 *      owner, these helpers print and record the calldata instead of sending, so the same
 *      script produces a multisig batch rather than reverting.
 */

const fs = require('fs')
const path = require('path')
const { ethers, network } = require('hardhat')

const NETWORK_DIRS = { fuse: 'Fuse', mainnet: 'Mainnet', base: 'Base' }

const REPO_ROOT = path.join(__dirname, '..', '..')

function networkDir() {
  return NETWORK_DIRS[network.name] || network.name
}

function deploymentFile() {
  const dir = path.join(REPO_ROOT, 'deployments', 'addresses', networkDir())
  fs.mkdirSync(dir, { recursive: true })
  return path.join(dir, 'SpendModule.json')
}

function loadDeployment() {
  const file = deploymentFile()
  if (!fs.existsSync(file)) return { contractAddresses: {} }
  return JSON.parse(fs.readFileSync(file, 'utf8'))
}

function saveAddress(name, address) {
  const file = deploymentFile()
  const record = loadDeployment()
  record.contractAddresses = record.contractAddresses || {}
  record.contractAddresses[name] = address
  record.network = network.name
  record.chainId = network.config.chainId
  fs.writeFileSync(file, JSON.stringify(record, null, 2) + '\n')
  console.log(`  recorded ${name} -> ${file}`)
}

/** Address of a previously deployed contract, or a clear failure naming the missing step. */
function requireAddress(name, step) {
  const address = loadDeployment().contractAddresses?.[name]
  if (!address) {
    throw new Error(`${name} not found in ${deploymentFile()} — run ${step} first`)
  }
  return address
}

function requireConfigured(value, label) {
  if (!value || value === ethers.constants.AddressZero) {
    throw new Error(`config.${label} is unset — fill it in scripts/spend-module/config.js before deploying`)
  }
  return value
}

/** Fails loudly rather than letting a later call decode empty returndata as a revert. */
async function requireHasCode(address, label) {
  const code = await ethers.provider.getCode(address)
  if (code === '0x') throw new Error(`${label} (${address}) has no code on ${network.name}`)
}

// ── Owner-aware sends ────────────────────────────────────────────────────────

const pending = []

/**
 * Calls `method` if the signer owns `contract`, otherwise records the calldata for the
 * owner multisig to submit.
 */
async function ownerCall(label, contract, method, args, ownerAddress) {
  const [signer] = await ethers.getSigners()

  if (signer.address.toLowerCase() !== ownerAddress.toLowerCase()) {
    const data = contract.interface.encodeFunctionData(method, args)
    pending.push({ label, to: contract.address, data })
    console.log(`  [queued for owner] ${label}`)
    return null
  }

  const tx = await contract[method](...args)
  await tx.wait()
  console.log(`  ${label} — tx ${tx.hash}`)
  return tx
}

/** Writes any queued owner transactions out as a batch, if there are any. */
function flushPending(name) {
  if (pending.length === 0) return
  const dir = path.join(REPO_ROOT, 'TimelockTxs', 'spend-module')
  fs.mkdirSync(dir, { recursive: true })
  const file = path.join(dir, `${networkDir()}-${name}.json`)
  fs.writeFileSync(file, JSON.stringify({ network: network.name, transactions: pending }, null, 2) + '\n')
  console.log(`\n${pending.length} transaction(s) require the owner. Batch written to:\n  ${file}`)
  pending.length = 0
}

/** Standard entrypoint: banner, signer, run, flush, exit. */
function run(name, main) {
  ;(async () => {
    const [signer] = await ethers.getSigners()
    console.log(`\n=== ${name} — network: ${network.name} (chainId ${network.config.chainId}) ===`)
    console.log(`Signer: ${signer.address}\n`)
    await main(signer)
    flushPending(name)
    console.log('')
  })()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error)
      process.exit(1)
    })
}

// ── Fully-qualified names, so a same-named contract elsewhere cannot be picked up ──
const FQN = {
  provider: 'src/spend-module/SolidPriceProvider.sol:SolidPriceProvider',
  module: 'src/spend-module/SolidCashModule.sol:SolidCashModule',
  lens: 'src/spend-module/SolidCashLens.sol:SolidCashLens',
  authority: 'src/fuse/FuseRolesAuthority.sol:FuseRolesAuthority',
}

module.exports = {
  FQN,
  loadDeployment,
  saveAddress,
  requireAddress,
  requireConfigured,
  requireHasCode,
  ownerCall,
  flushPending,
  run,
}
