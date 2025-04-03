const { ethers } = require('hardhat')

async function main() {
  const rolesAuthorityAddr = '0x83240381490cf6d130d188372234a01356e6bb95'
  const fuseTellerAddr = '0xECdD84DE002EF36fB0698dAf7e767Ae0b8630920'

  const MINTER_ROLE = 2
  const BURNER_ROLE = 3

  const [signer] = await ethers.getSigners()
  console.log(`🔐 Using signer: ${signer.address}`)

  const rolesAbi = [
    'function setUserRole(address user, uint8 role, bool enabled) external',
  ]
  const auth = new ethers.Contract(rolesAuthorityAddr, rolesAbi, signer)

  console.log(`🔐 Granting MINTER_ROLE to ${fuseTellerAddr}...`)
  const tx1 = await auth.setUserRole(fuseTellerAddr, MINTER_ROLE, true)
  await tx1.wait()
  console.log('✅ MINTER_ROLE granted')

  console.log(`🔐 Granting BURNER_ROLE to ${fuseTellerAddr}...`)
  const tx2 = await auth.setUserRole(fuseTellerAddr, BURNER_ROLE, true)
  await tx2.wait()
  console.log('✅ BURNER_ROLE granted')
}

main().catch((err) => {
  console.error('❌ Error:', err)
  process.exit(1)
})
