const { ethers } = require('hardhat')

async function main() {
  const vaultReceiverAddr = '0xYourVaultRateReceiverOnFuse'
  const ethSenderAddr = '0xYourVaultRateSenderOnEthereum'
  const ethereumChainId = 101 // LayerZero chain ID for Ethereum

  const [signer] = await ethers.getSigners()
  const receiver = await ethers.getContractAt(
    'VaultRateReceiver',
    vaultReceiverAddr,
    signer
  )

  const trustedRemote = ethers.utils.solidityPack(
    ['address', 'address'],
    [ethSenderAddr, vaultReceiverAddr]
  )

  const tx = await receiver.setTrustedRemote(ethereumChainId, trustedRemote)
  await tx.wait()
  console.log('✅ Fuse: setTrustedRemote -> Ethereum')
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
