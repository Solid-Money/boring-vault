const { ethers } = require('hardhat')
const {
  MAINNET_CHAIN_ID,
  BASE_CHAIN_ID,
  PROFILE,
  profile,
  required,
  vaultToken,
  decoderDeploy,
  requireNetwork,
  readDeployed,
  recordDeployed,
  loadArtifact,
  sendTx,
  waitForCode,
} = require('./config')

// SolidCrossChainTokenDecoderAndSanitizer through the CREATE2 factory: run on mainnet and on base. The
// decoder has no constructor arguments, so the same build lands at the same address on both chains.
// Safe to re-run: an existing deployment at the predicted address is recorded, not redeployed.

const RECORD_NAME = 'SolidCrossChainTokenDecoderAndSanitizer'

function predictDecoder() {
  const { bytecode } = loadArtifact('Decoder')
  return ethers.utils.getCreate2Address(
    decoderDeploy.create2Factory,
    decoderDeploy.salt,
    ethers.utils.keccak256(bytecode),
  )
}

// On Base, check the profile points at the live soEUR vault and its manager before recording.
async function checkBaseVault() {
  const vaultAddress = required(profile.base.vault, 'base.vault')
  const managerAddress = required(profile.base.manager, 'base.manager')
  const vault = new ethers.Contract(
    vaultAddress,
    [
      'function name() view returns (string)',
      'function symbol() view returns (string)',
      'function decimals() view returns (uint8)',
    ],
    ethers.provider,
  )
  const [name, symbol, decimals] = await Promise.all([vault.name(), vault.symbol(), vault.decimals()])
  if (name !== vaultToken.name || symbol !== vaultToken.symbol || decimals !== vaultToken.decimals) {
    throw new Error(
      `Base vault ${vaultAddress} is ${name}/${symbol}/${decimals}, expected ${JSON.stringify(vaultToken)}`,
    )
  }
  const manager = new ethers.Contract(managerAddress, ['function vault() view returns (address)'], ethers.provider)
  const managedVault = await manager.vault()
  if (managedVault.toLowerCase() !== vaultAddress.toLowerCase()) {
    throw new Error(`Base manager ${managerAddress} manages ${managedVault}, not the soEUR vault ${vaultAddress}`)
  }
}

async function deployDecoder() {
  const chainId = await requireNetwork(MAINNET_CHAIN_ID, BASE_CHAIN_ID)
  if (chainId === BASE_CHAIN_ID) await checkBaseVault()

  const { bytecode } = loadArtifact('Decoder')
  const predicted = predictDecoder()

  // Either chain's record must match this build, or the two chains would end up with different decoders.
  for (const id of [MAINNET_CHAIN_ID, BASE_CHAIN_ID]) {
    const recorded = readDeployed(id)[RECORD_NAME]
    if (recorded && recorded.toLowerCase() !== predicted.toLowerCase()) {
      throw new Error(
        `Chain ${id} records the decoder at ${recorded}, but this build predicts ${predicted}; the decoder bytecode changed since it was deployed`,
      )
    }
  }

  if ((await ethers.provider.getCode(predicted)) === '0x') {
    console.log(`Deploying soEUR (${PROFILE}) decoder through CREATE2...`)
    const [signer] = await ethers.getSigners()
    await sendTx(
      signer.sendTransaction({
        to: decoderDeploy.create2Factory,
        data: ethers.utils.hexConcat([decoderDeploy.salt, bytecode]),
      }),
    )
    await waitForCode(predicted)
  } else {
    console.log('Decoder already deployed at the predicted address')
  }
  console.log('Decoder:', predicted)
  if (!readDeployed(chainId)[RECORD_NAME]) recordDeployed(chainId, RECORD_NAME, predicted)
  return predicted
}

if (require.main === module) {
  deployDecoder()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error)
      process.exit(1)
    })
}

module.exports = { deployDecoder, predictDecoder }
