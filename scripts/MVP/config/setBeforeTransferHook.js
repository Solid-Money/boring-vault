const { ethers } = require('hardhat')
const deployment = require('../deployment').load()

// ── Config ──────────────────────────────────────────────────────────────────
const vaultAddress = deployment.address('BoringVault')
const tellerAddress = deployment.address('Teller')

// ── Execute ─────────────────────────────────────────────────────────────────
async function main() {
  await deployment.check(ethers)
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
