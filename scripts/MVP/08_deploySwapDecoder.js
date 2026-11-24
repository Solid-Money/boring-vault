const { ethers } = require('hardhat')
const deployment = require('./deployment').load()

// The stock vaults' swap decoder: lets the Manager check KyberSwap swaps against the manage root,
// so the strategist can turn the vault's Merkl rewards into more stock. Like the stock decoder it
// has no state, owner or vault-specific setting, so one deployment serves every stock vault:
// deploy it once, then record that address on the others with SWAP_DECODER=<address>.
async function main() {
  await deployment.check(ethers)

  const existing = deployment.optionalAddress('SwapDecoder')
  if (existing) {
    console.log('SwapDecoder already recorded:', existing)
    return
  }

  let address = process.env.SWAP_DECODER
  if (address) {
    if (!ethers.utils.isAddress(address)) throw new Error(`SWAP_DECODER ${address} is not an address`)
    if ((await ethers.provider.getCode(address)) === '0x') throw new Error(`Nothing is deployed at SWAP_DECODER ${address}`)
    address = ethers.utils.getAddress(address)
    console.log('Recording the shared KyberswapRouterDecoderAndSanitizer:', address)
  } else {
    const Decoder = await ethers.getContractFactory(
      'src/base/DecodersAndSanitizers/Solid/KyberswapRouterDecoderAndSanitizer.sol:KyberswapRouterDecoderAndSanitizer'
    )
    const decoder = await Decoder.deploy()
    await decoder.deployed()
    address = decoder.address
    console.log('KyberswapRouterDecoderAndSanitizer deployed at:', address)
  }
  deployment.save('SwapDecoder', address)
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
