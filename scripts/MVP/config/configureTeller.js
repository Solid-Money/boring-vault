const { ethers } = require('hardhat')
const deployment = require('../deployment').load()

// ── Config ──────────────────────────────────────────────────────────────────
const tellerAddress = deployment.address('Teller')

// updateAssetData: configure accepted deposit tokens
// Never list native ETH (0xEeee…EEeE) here: each vault only takes its base asset.
const depositAssets = [
  {
    asset: deployment.config.baseAsset, // EURC for soEUR, the stock token for soAAPL and the like
    allowDeposits: true,
    allowWithdraws: true,
    sharePremium: 0,
  },
]

// ── Execute ─────────────────────────────────────────────────────────────────
async function main() {
  await deployment.check(ethers)
  const [deployer] = await ethers.getSigners()
  console.log('Configuring teller at:', tellerAddress)
  console.log('Signer:', deployer.address)
  console.log('---')

  const teller = await ethers.getContractAt(
    'src/base/Roles/TellerWithMultiAssetSupport.sol:TellerWithMultiAssetSupport',
    tellerAddress
  )

  // updateAssetData — configure accepted deposit tokens
  for (const asset of depositAssets) {
    console.log(`Updating asset data for ${asset.asset}...`)
    const tx = await teller.updateAssetData(
      asset.asset,
      asset.allowDeposits,
      asset.allowWithdraws,
      asset.sharePremium
    )
    await tx.wait()
    console.log(`Asset configured: deposits=${asset.allowDeposits}, withdraws=${asset.allowWithdraws}, premium=${asset.sharePremium}`)
  }
  console.log('---')

  console.log('Teller configuration complete.')
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
