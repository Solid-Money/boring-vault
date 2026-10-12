const { ethers } = require('hardhat')

// ── Config ──────────────────────────────────────────────────────────────────
const tellerAddress = '0x4149c11b479B26080428Dc5e688F4D27253C4783' // TODO: fill after deployment

// setPeer: register the destination chain teller as a trusted peer
const destinationEid = 30138 // LayerZero endpoint ID for Fuse
const destinationTellerAddress = '0xEaacf4534cCC05CAd929830fAF611d872b291d41' // TODO: teller address on the destination chain

// addChain: configure cross-chain communication
const chainId = 30138 // destination chain ID (Fuse)
const allowMessagesFrom = true
const allowMessagesTo = true
const targetTellerAddress = destinationTellerAddress
const messageGasLimit = 300000

// updateAssetData: configure accepted deposit tokens
const depositAssets = [
  {
    asset: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2', // WETH
    allowDeposits: true,
    allowWithdraws: true,
    sharePremium: 0,
  },
  {
    asset: '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE', // ETH
    allowDeposits: true,
    allowWithdraws: true,
    sharePremium: 0,
  },
]

// ── Execute ─────────────────────────────────────────────────────────────────
async function main() {
  const [deployer] = await ethers.getSigners()
  console.log('Configuring teller at:', tellerAddress)
  console.log('Signer:', deployer.address)
  console.log('---')

  const teller = await ethers.getContractAt(
    'src/base/Roles/CrossChain/Bridges/LayerZero/LayerZeroTeller.sol:LayerZeroTeller',
    tellerAddress
  )

  // 1. setPeer — register destination chain teller as trusted peer
  console.log('Setting peer...')
  const peerBytes32 = ethers.utils.hexZeroPad(destinationTellerAddress, 32)
  const tx1 = await teller.setPeer(destinationEid, peerBytes32)
  await tx1.wait()
  console.log(`Peer set: eid=${destinationEid}, peer=${destinationTellerAddress}`)
  console.log('---')

  // 2. addChain — configure cross-chain communication parameters
  console.log('Adding chain...')
  const tx2 = await teller.addChain(
    chainId,
    allowMessagesFrom,
    allowMessagesTo,
    targetTellerAddress,
    messageGasLimit
  )
  await tx2.wait()
  console.log(`Chain added: chainId=${chainId}, from=${allowMessagesFrom}, to=${allowMessagesTo}, gasLimit=${messageGasLimit}`)
  console.log('---')

  // 3. updateAssetData — configure accepted deposit tokens
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
