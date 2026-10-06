const { ethers } = require('hardhat')

// ── Config ──────────────────────────────────────────────────────────────────
const vaultAddress = '0xf9039d4f49686F34936b6937D13bBbe413f910c4'
const tellerAddress = '0x4149c11b479B26080428Dc5e688F4D27253C4783'

// ── Execute ─────────────────────────────────────────────────────────────────
async function main() {
  const [deployer] = await ethers.getSigners()
  console.log('Signer:', deployer.address)

  const vault = await ethers.getContractAt(
    'src/base/BoringVault.sol:BoringVault',
    vaultAddress
  )

  console.log('Setting beforeTransferHook to teller:', tellerAddress)
  const tx = await vault.setBeforeTransferHook(tellerAddress)
  await tx.wait()
  console.log('BeforeTransferHook set successfully.')
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
