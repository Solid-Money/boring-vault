const { ethers } = require('hardhat')

async function main() {
  const FuseTeller = await ethers.getContractFactory('FuseTeller')
  const fuseTeller = await FuseTeller.deploy()
  await fuseTeller.deployed()

  console.log('Fuse teller deployed at:', fuseTeller.address)
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
