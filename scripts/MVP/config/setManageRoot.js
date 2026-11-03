const fs = require('fs')
const path = require('path')
const { ethers } = require('hardhat')
const deployment = require('../deployment').load()
const { stockLeafs, buildTree, treeFile, treeFilePath } = require('../strategy/leafs')

// ── Config ──────────────────────────────────────────────────────────────────
// Gives the strategist its manage root: deposit the stock token into the vault's Superform
// SuperVault, redeem it back, and claim the SuperVault's Merkl rewards. Nothing else.
// Writes every leaf with its proof to leafs/Base/<symbol>StrategistLeafs.json for the strategist.
const managerAddress = deployment.address('Manager')
const decoderAddress = deployment.address('Decoder')
const strategist = deployment.config.strategist

// ── Execute ─────────────────────────────────────────────────────────────────
async function main() {
  await deployment.check(ethers)
  const [signer] = await ethers.getSigners()
  console.log('Signer:', signer.address)

  const leafs = stockLeafs({ boringVault: deployment.address('BoringVault'), decoder: decoderAddress, config: deployment.config })
  const root = buildTree(leafs)
  const out = treeFilePath(deployment)
  fs.writeFileSync(out,JSON.stringify(treeFile({ deployment, decoder: decoderAddress, leafs, root }), null, 2) + '\n')
  console.log(`${leafs.length} leafs, root ${root}, written to ${path.relative(process.cwd(), out)}`)

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
