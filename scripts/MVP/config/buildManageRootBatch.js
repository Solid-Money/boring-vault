const fs = require('fs')
const path = require('path')
const { ethers } = require('hardhat')

// One owner-Safe batch that sets the strategist's manage root on every stock vault's Manager, from
// the tree files config/setManageRoot.js wrote (run it with WRITE_ONLY=1 for each vault first).
// Prod records only: the stock vaults have no QA deployment.
//
//   npx hardhat run scripts/MVP/config/buildManageRootBatch.js --network base
//
// Writes deployments/safe-batches/base-stock-vault-reward-roots.json for the Safe Transaction
// Builder. Before writing, it checks on Base that the Safe owns each Manager, that the strategist's
// current root is the record's tree minus the reward leafs (so the batch only adds), and that each
// tree carries the reward conversion.
const STOCK_VAULTS = ['soAAPL', 'soNVDA', 'soAMZN', 'soMSFT', 'soMETA', 'soTSLA', 'soGOOGL', 'soSPCX']
const REPO = path.join(__dirname, '..', '..', '..')
const OUT = path.join(REPO, 'deployments', 'safe-batches', 'base-stock-vault-reward-roots.json')

const managerAbi = [
  'function owner() view returns (address)',
  'function manageRoot(address) view returns (bytes32)',
  'function setManageRoot(address strategist, bytes32 _manageRoot)',
]

async function main() {
  const { chainId } = await ethers.provider.getNetwork()
  if (chainId !== 8453) throw new Error(`Connected to chain ${chainId}, not Base`)
  const { stockLeafs, buildTree } = require('../strategy/leafs')

  let safe
  const transactions = []
  for (const symbol of STOCK_VAULTS) {
    const record = JSON.parse(fs.readFileSync(path.join(REPO, 'deployments', 'addresses', 'Base', `${symbol}.json`), 'utf8'))
    const tree = JSON.parse(fs.readFileSync(path.join(REPO, 'leafs', 'Base', `${symbol}StrategistLeafs.json`), 'utf8'))
    const { config, contracts } = record
    const { metadata } = tree

    if (!contracts.SwapDecoder) throw new Error(`${symbol} has no SwapDecoder: run 08_deploySwapDecoder.js for it`)
    if (metadata.SwapDecoderAndSanitizerAddress !== contracts.SwapDecoder) {
      throw new Error(`${symbol}'s tree file was not built with its SwapDecoder: rerun setManageRoot.js with WRITE_ONLY=1`)
    }
    if (metadata.ManagerAddress !== contracts.Manager || metadata.BoringVaultAddress !== contracts.BoringVault) {
      throw new Error(`${symbol}'s tree file is for another vault`)
    }

    // Rebuild both trees from the record, so the batch never trusts a hand-edited file.
    const args = { boringVault: contracts.BoringVault, decoder: contracts.Decoder, config }
    const newRoot = buildTree(stockLeafs({ ...args, swapDecoder: contracts.SwapDecoder }))
    const oldRoot = buildTree(stockLeafs(args))
    if (newRoot !== metadata.ManageRoot) throw new Error(`${symbol}'s tree file root ${metadata.ManageRoot} is not the record's ${newRoot}`)

    const manager = new ethers.Contract(contracts.Manager, managerAbi, ethers.provider)
    const [owner, liveRoot] = await Promise.all([manager.owner(), manager.manageRoot(config.strategist)])
    if (owner.toLowerCase() !== config.owner.toLowerCase()) throw new Error(`${symbol}'s Manager is owned by ${owner}, not ${config.owner}`)
    safe = safe || owner
    if (owner.toLowerCase() !== safe.toLowerCase()) throw new Error(`${symbol}'s Manager has a different owner from the others`)
    if (liveRoot === newRoot) {
      console.log(`${symbol}: already on ${newRoot}, skipped`)
      continue
    }
    if (liveRoot !== oldRoot) {
      throw new Error(`${symbol}'s live root ${liveRoot} is neither the strategy-only root ${oldRoot} nor the new one: check what was set`)
    }

    console.log(`${symbol}: ${liveRoot} -> ${newRoot} (${tree.leafs.length} leafs)`)
    transactions.push({
      to: contracts.Manager,
      value: '0',
      data: null,
      contractMethod: {
        inputs: [
          { internalType: 'address', name: 'strategist', type: 'address' },
          { internalType: 'bytes32', name: '_manageRoot', type: 'bytes32' },
        ],
        name: 'setManageRoot',
        payable: false,
      },
      contractInputsValues: { strategist: config.strategist, _manageRoot: newRoot },
    })
  }

  if (transactions.length === 0) {
    console.log('Every stock vault already has its new root; nothing to write')
    return
  }
  const batch = {
    version: '1.0',
    chainId: '8453',
    createdAt: Date.now(),
    meta: {
      name: 'Stock vaults: let the strategist compound Merkl rewards',
      description:
        "Sets each stock vault's strategist manage root to one that adds the reward conversion: redeem sUP to UP, and swap USDC and UP into the stock on KyberSwap. Every leaf of the current root stays.",
      txBuilderVersion: '1.18.0',
      createdFromSafeAddress: safe,
    },
    transactions,
  }
  fs.mkdirSync(path.dirname(OUT), { recursive: true })
  fs.writeFileSync(OUT, JSON.stringify(batch, null, 2) + '\n')
  console.log(`${transactions.length} transactions for Safe ${safe}, written to ${path.relative(process.cwd(), OUT)}`)
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
