const { ethers } = require('hardhat')

const ownerAddress = '0x3B694d634981Ace4B64a27c48bffe19f1447779B'

async function main() {
  const destinationId = 30332; // your uint32 value
  const encoded = ethers.utils.defaultAbiCoder.encode(['uint32'], [destinationId]);

  // If you need to decode it back
  const decoded = ethers.utils.defaultAbiCoder.decode(['uint32'], encoded);

  console.log(`Encoded:`, encoded)
  console.log(`Decoded:`, decoded)
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
