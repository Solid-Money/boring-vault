const { ethers } = require('hardhat')

async function main() {
  const vaultSenderAddr = '0xYourVaultRateSenderOnEthereum'
  const fuseReceiverAddr = '0xYourVaultRateReceiverOnFuse'
  const fuseChainId = 122 // LayerZero chain ID for Fuse

  const [signer] = await ethers.getSigners()
  const sender = await ethers.getContractAt(
    'VaultRateSender',
    vaultSenderAddr,
    signer
  )

  const trustedRemote = ethers.utils.solidityPack(
    ['address', 'address'],
    [fuseReceiverAddr, vaultSenderAddr]
  )

  const tx = await sender.setTrustedRemote(fuseChainId, trustedRemote)
  await tx.wait()
  console.log('✅ Ethereum: setTrustedRemote -> Fuse')
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
