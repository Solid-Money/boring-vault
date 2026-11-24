const fs = require('fs')
const path = require('path')
const { ethers } = require('hardhat')
const deployment = require('../deployment').load()
const { stockLeafs, buildTree, treeFile, treeFilePath } = require('../strategy/leafs')

// ── Config ──────────────────────────────────────────────────────────────────
// Gives the strategist its manage root: deposit the stock token into the vault's Superform
// SuperVault, redeem it back, and claim the SuperVault's Merkl rewards. Once the vault has a
// SwapDecoder (08_deploySwapDecoder.js) the root also lets the strategist turn those rewards into
// more stock: redeem sUP to UP, then swap USDC and UP into the stock on KyberSwap.
// Writes every leaf with its proof to leafs/Base/<symbol>StrategistLeafs.json for the strategist.
//
// The deployer sets the root during deployment. A live vault belongs to the owner Safe, so with
// WRITE_ONLY=1 this only writes the tree file; config/buildManageRootBatch.js then turns the tree
// files into one Safe batch.
const managerAddress = deployment.address('Manager')
const decoderAddress = deployment.address('Decoder')
const swapDecoderAddress = deployment.optionalAddress('SwapDecoder')
const strategist = deployment.config.strategist

// ── Execute ─────────────────────────────────────────────────────────────────
async function main() {
  await deployment.check(ethers)

  const leafs = stockLeafs({
    boringVault: deployment.address('BoringVault'),
    decoder: decoderAddress,
    swapDecoder: swapDecoderAddress,
    config: deployment.config,
  })
  const root = buildTree(leafs)
  const out = treeFilePath(deployment)
  fs.writeFileSync(
    out,
    JSON.stringify(treeFile({ deployment, decoder: decoderAddress, swapDecoder: swapDecoderAddress, leafs, root }), null, 2) + '\n'
  )
  console.log(`${leafs.length} leafs, root ${root}, written to ${path.relative(process.cwd(), out)}`)

  if (process.env.WRITE_ONLY === '1') {
    console.log('WRITE_ONLY=1: not setting the root; the owner Safe sets it')
    return
  }

  const [signer] = await ethers.getSigners()
  console.log('Signer:', signer.address)
  const manager = await ethers.getContractAt(
    'src/base/Roles/ManagerWithMerkleVerification.sol:ManagerWithMerkleVerification',
    managerAddress
  )
  console.log(`Setting the manage root for strategist ${strategist}`)
  const tx = await manager.setManageRoot(strategist, root)
  await tx.wait()
  console.log('  tx:', tx.hash)
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
