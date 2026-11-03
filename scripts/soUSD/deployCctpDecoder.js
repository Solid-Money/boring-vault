const fs = require('fs')
const path = require('path')
const { ethers } = require('hardhat')

// SolidCCTPDecoderAndSanitizer through the CREATE2 factory, for soUSD's USDC bridge between Ethereum and
// Base over Circle's CCTP V2 (approve TokenMessengerV2 + depositForBurn). It has no constructor arguments,
// so the same build lands at the same address on both chains, and QA and prod share it.
// Safe to re-run: an existing deployment at the predicted address is left alone.
//
//   forge build src/base/DecodersAndSanitizers/Solid/SolidCCTPDecoderAndSanitizer.sol
//   npx hardhat run --no-compile scripts/soUSD/deployCctpDecoder.js --network mainnet
//   npx hardhat run --no-compile scripts/soUSD/deployCctpDecoder.js --network base
//   PREDICT_ONLY=1 npx hardhat run --no-compile scripts/soUSD/deployCctpDecoder.js --network base
//
// Then set CCTP_DECODER_ADDRESS_ETHEREUM and CCTP_DECODER_ADDRESS_BASE in the backend to the printed
// address. The backend's soUSD trees gain approve(TokenMessengerV2) + depositForBurn leaves on this
// decoder; the owner calls setManageRoot(strategist, root) on BOTH soUSD managers with the new roots.

const MAINNET_CHAIN_ID = 1
const BASE_CHAIN_ID = 8453

const SOURCE = 'src/base/DecodersAndSanitizers/Solid/SolidCCTPDecoderAndSanitizer.sol'
const NAME = 'SolidCCTPDecoderAndSanitizer'

const create2Factory = '0x4e59b44847b379578588920cA78FbF26c0B4956C'
const salt = ethers.utils.id('SolidSoUSD.CCTPDecoderAndSanitizer.v1')

// ethers v5 hardcodes a 1.5 gwei priority fee, ~300x Base's real cost; use the node's suggested tip.
const providerPrototype = Object.getPrototypeOf(ethers.provider)
const defaultGetFeeData = providerPrototype.getFeeData
providerPrototype.getFeeData = async function () {
  const feeData = await defaultGetFeeData.call(this)
  if (!feeData.lastBaseFeePerGas) return feeData
  const maxPriorityFeePerGas = ethers.BigNumber.from(await this.send('eth_maxPriorityFeePerGas', []))
  return {
    ...feeData,
    maxPriorityFeePerGas,
    maxFeePerGas: feeData.lastBaseFeePerGas.mul(2).add(maxPriorityFeePerGas),
  }
}

// Foundry's artifact, from artifacts/ or out/ (whichever is newer), checked to come from SOURCE.
function loadBytecode() {
  const candidates = ['artifacts', 'out']
    .map((dir) => path.join(__dirname, '../..', dir, path.basename(SOURCE), `${NAME}.json`))
    .filter((file) => fs.existsSync(file))
    .sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs)
  if (candidates.length === 0) throw new Error(`No artifact for ${NAME}; run \`forge build ${SOURCE}\``)
  const artifact = JSON.parse(fs.readFileSync(candidates[0], 'utf8'))
  const target = artifact.metadata && artifact.metadata.settings.compilationTarget
  if (!target || target[SOURCE] !== NAME) {
    throw new Error(`${candidates[0]} was built from ${JSON.stringify(target)}, expected ${SOURCE}`)
  }
  return artifact.bytecode.object
}

async function main() {
  const { chainId } = await ethers.provider.getNetwork()
  if (chainId !== MAINNET_CHAIN_ID && chainId !== BASE_CHAIN_ID) {
    throw new Error(`Expected chainId ${MAINNET_CHAIN_ID} or ${BASE_CHAIN_ID}, connected to ${chainId}`)
  }
  const bytecode = loadBytecode()
  const predicted = ethers.utils.getCreate2Address(create2Factory, salt, ethers.utils.keccak256(bytecode))
  console.log(`${NAME}: ${predicted}`)
  if (process.env.PREDICT_ONLY) return

  if ((await ethers.provider.getCode(predicted)) !== '0x') {
    console.log('Already deployed at the predicted address')
    return
  }
  console.log(`Deploying on chain ${chainId} through CREATE2...`)
  const [signer] = await ethers.getSigners()
  const tx = await signer.sendTransaction({ to: create2Factory, data: ethers.utils.hexConcat([salt, bytecode]) })
  console.log(`  tx: ${tx.hash}`)
  await tx.wait(2)
  for (let attempt = 0; attempt < 60; attempt++) {
    if ((await ethers.provider.getCode(predicted)) !== '0x') {
      console.log('Deployed')
      return
    }
    await new Promise((resolve) => setTimeout(resolve, 2000))
  }
  throw new Error(`No code at ${predicted} after 2 minutes`)
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
