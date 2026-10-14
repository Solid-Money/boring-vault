const { ethers } = require('hardhat')

// ── Config ──────────────────────────────────────────────────────────────────
// Points each contract at the RolesAuthority, skipping any that already do. deployAll.js does this
// too; this repairs a setAuthority that did not land (on Base the Manager's ran out of gas because
// the gas was estimated on an RPC node that had not seen the new contract yet).
const authorityAddress = '0x7F66AF3C7B7D80d6d4be937dE81cad42C0277eE3' // Base: RolesAuthority, from deployAll.js output
const boringVaultAddress = '0x1c6B29c8ac1E12A34D74DdaFCF016246d6aEdfff' // Base: from deployAll.js output
const accountantAddress = '0x23710C9fdF34b7E1eF28A92a19F9fdC0aC99518c' // Base: from deployAll.js output
const tellerAddress = '0xb02796D0b8e1f39265C48e31c94a48c428266Ddb' // Base: Teller, from deployAll.js output
const managerAddress = '0x4a90736b26353fea5C85f5cF941D85373C68AD0D' // Base: from deployAll.js output

const authAbi = [
  'function authority() view returns (address)',
  'function setAuthority(address newAuthority) external',
]

// ── Execute ─────────────────────────────────────────────────────────────────
async function main() {
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
