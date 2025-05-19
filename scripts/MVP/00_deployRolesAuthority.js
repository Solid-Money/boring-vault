const { ethers } = require('hardhat')

const ownerAddress = '0x3B694d634981Ace4B64a27c48bffe19f1447779B'

async function main() {
  console.log('Deploying RolesAuthority...')
  // Deploy RolesAuthority
  const RolesAuthority = await ethers.getContractFactory('FuseRolesAuthority')
  const authority = await RolesAuthority.deploy(
    ownerAddress,
    ownerAddress
  )
  await authority.deployed()

  console.log(`RolesAuthority deployed at:`, authority.address)
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
