const { ethers } = require('hardhat')
const deployment = require('../deployment').load()

// ── Config ──────────────────────────────────────────────────────────────────
// Points each contract at the RolesAuthority, skipping any that already do. deployAll.js does this
// too; this repairs a setAuthority that did not land (on Base the Manager's ran out of gas because
// the gas was estimated on an RPC node that had not seen the new contract yet).
const authorityAddress = deployment.address('RolesAuthority')
const boringVaultAddress = deployment.address('BoringVault')
const accountantAddress = deployment.address('Accountant')
const tellerAddress = deployment.address('Teller')
const managerAddress = deployment.address('Manager')

const authAbi = [
  'function authority() view returns (address)',
  'function setAuthority(address newAuthority) external',
]

// ── Execute ─────────────────────────────────────────────────────────────────
async function main() {
  await deployment.check(ethers)
  const [deployer] = await ethers.getSigners()
  console.log('Signer:', deployer.address)

  const contracts = [
    ['BoringVault', boringVaultAddress],
    ['Accountant', accountantAddress],
    ['Teller', tellerAddress],
    ['Manager', managerAddress],
  ]
  for (const [name, address] of contracts) {
    const contract = new ethers.Contract(address, authAbi, deployer)
    if ((await contract.authority()).toLowerCase() === authorityAddress.toLowerCase()) {
      console.log(`${name}: authority already set`)
      continue
    }
    console.log(`${name}: setting authority to ${authorityAddress}...`)
    // Fixed gas limit instead of an estimate, for the reason above. wait() throws if the tx fails.
    const tx = await contract.setAuthority(authorityAddress, { gasLimit: 100000 })
    await tx.wait()
    console.log('  tx:', tx.hash)
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
