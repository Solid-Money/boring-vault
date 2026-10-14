const { ethers } = require('hardhat')

// ── Config ──────────────────────────────────────────────────────────────────
const boringQueueAddress = '0xf68057c26eaF1F49800EaE86046B2b70Bd8Ded06' // Base: from 05_deployBoringQueue.js output

// Same parameters as the live soETH queue on Ethereum (withdrawAssets(WETH)).
const withdrawAsset = '0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42' // EURC on Base
const secondsToMaturity = 120
const minimumSecondsToDeadline = 259200 // 3 days
const minDiscount = 1 // bps
const maxDiscount = 100 // bps
const minimumShares = 100 // raw share units (soEURC has 6 decimals)

// ── Execute ─────────────────────────────────────────────────────────────────
async function main() {
  const [deployer] = await ethers.getSigners()
  console.log('Signer:', deployer.address)

  const queue = await ethers.getContractAt(
    'src/base/Roles/BoringQueue/BoringOnChainQueueWithTracking.sol:BoringOnChainQueueWithTracking',
    boringQueueAddress
  )

  console.log('Setting withdraw asset on queue:', withdrawAsset)
  const tx = await queue.updateWithdrawAsset(
    withdrawAsset,
    secondsToMaturity,
    minimumSecondsToDeadline,
    minDiscount,
    maxDiscount,
    minimumShares
  )
  await tx.wait()
  console.log('  tx:', tx.hash)
  console.log('Withdraw asset configured.')
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
