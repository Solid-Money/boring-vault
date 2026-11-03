const { ethers } = require('hardhat')
const deployment = require('./deployment').load()

// The stock vaults' decoder: lets the Manager check SuperVault and Merkl calls against the manage
// root. It has no state or owner, so each vault simply gets its own.
async function main() {
  await deployment.check(ethers)

  const Decoder = await ethers.getContractFactory(
    'src/base/DecodersAndSanitizers/Solid/SolidStocksDecoderAndSanitizer.sol:SolidStocksDecoderAndSanitizer'
  )
  const decoder = await Decoder.deploy()
  await decoder.deployed()

  console.log('SolidStocksDecoderAndSanitizer deployed at:', decoder.address)
  deployment.save('Decoder', decoder.address)
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
