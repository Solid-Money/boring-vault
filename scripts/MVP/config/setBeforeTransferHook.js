const { ethers } = require('hardhat')

// ── Config ──────────────────────────────────────────────────────────────────
const vaultAddress = '0x1c6B29c8ac1E12A34D74DdaFCF016246d6aEdfff' // Base: from deployAll.js output
const tellerAddress = '0xb02796D0b8e1f39265C48e31c94a48c428266Ddb' // Base: from deployAll.js output

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
