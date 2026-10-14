const { ethers } = require('hardhat')

// ==================== DEPLOYED ADDRESSES ====================
const authorityAddress = '0x7F66AF3C7B7D80d6d4be937dE81cad42C0277eE3' // Base: RolesAuthority, from deployAll.js output
const boringVaultAddress = '0x1c6B29c8ac1E12A34D74DdaFCF016246d6aEdfff' // Base: from deployAll.js output
const accountantAddress = '0x23710C9fdF34b7E1eF28A92a19F9fdC0aC99518c' // Base: from deployAll.js output
const tellerAddress = '0xb02796D0b8e1f39265C48e31c94a48c428266Ddb' // Base: Teller, from deployAll.js output
const managerAddress = '0x4a90736b26353fea5C85f5cF941D85373C68AD0D' // Base: from deployAll.js output
const strategistEOA = '0x78fD5DC01824d707090a76059c87a88FD7944a0E' // Strategist EOA, same as soETH

// ==================== ROLE IDs ====================
const MANAGER_ROLE = 1
const MINTER_ROLE = 2
const BURNER_ROLE = 3
const STRATEGIST_ROLE = 7
const UPDATE_EXCHANGE_RATE_ROLE = 11

// ==================== FUNCTION SELECTORS ====================
const MANAGE_SELECTOR = '0xf6e715d0' // BoringVault.manage
const ENTER_SELECTOR = '0x39d6ba32' // BoringVault.enter
const EXIT_SELECTOR = '0x18457e61' // BoringVault.exit
const UPDATE_EXCHANGE_RATE_SELECTOR = '0x3458113d' // Accountant.updateExchangeRate
const MANAGE_VAULT_MERKLE_SELECTOR = '0x244b0f6a' // Manager.manageVaultWithMerkleVerification
const DEPOSIT_SELECTOR = '0x0efe6a8b' // Teller.deposit

// ==================== ABI ====================
const authorityAbi = [
  'function setRoleCapability(uint8 role, address target, bytes4 functionSig, bool enabled) external',
  'function setUserRole(address user, uint8 role, bool enabled) external',
  'function setPublicCapability(address target, bytes4 functionSig, bool enabled) external',
]

async function main() {
  const [deployer] = await ethers.getSigners()
  console.log('Deployer address:', deployer.address)

  const authority = new ethers.Contract(authorityAddress, authorityAbi, deployer)

  // ==================== ROLE CAPABILITIES ====================
  // Define what each role is allowed to do

  // Role 1 — Manager can call manage() on BoringVault
  console.log('Setting Role 1: Manager -> BoringVault.manage')
  let tx = await authority.setRoleCapability(MANAGER_ROLE, boringVaultAddress, MANAGE_SELECTOR, true)
  await tx.wait()
  console.log('  tx:', tx.hash)

  // Role 2 — Minter can call enter() on BoringVault
  console.log('Setting Role 2: Minter -> BoringVault.enter')
  tx = await authority.setRoleCapability(MINTER_ROLE, boringVaultAddress, ENTER_SELECTOR, true)
  await tx.wait()
  console.log('  tx:', tx.hash)

  // Role 3 — Burner can call exit() on BoringVault
  console.log('Setting Role 3: Burner -> BoringVault.exit')
  tx = await authority.setRoleCapability(BURNER_ROLE, boringVaultAddress, EXIT_SELECTOR, true)
  await tx.wait()
  console.log('  tx:', tx.hash)

  // Role 11 — UpdateExchangeRate can call updateExchangeRate() on Accountant
  console.log('Setting Role 11: UpdateExchangeRate -> Accountant.updateExchangeRate')
  tx = await authority.setRoleCapability(UPDATE_EXCHANGE_RATE_ROLE, accountantAddress, UPDATE_EXCHANGE_RATE_SELECTOR, true)
  await tx.wait()
  console.log('  tx:', tx.hash)

  // Role 7 — Strategist can call manageVaultWithMerkleVerification() on Manager
  console.log('Setting Role 7: Strategist -> Manager.manageVaultWithMerkleVerification')
  tx = await authority.setRoleCapability(STRATEGIST_ROLE, managerAddress, MANAGE_VAULT_MERKLE_SELECTOR, true)
  await tx.wait()
  console.log('  tx:', tx.hash)

  // ==================== USER ROLE ASSIGNMENTS ====================
  // Assign roles to specific addresses

  // Manager contract gets MANAGER_ROLE
  console.log('Assigning MANAGER_ROLE to ManagerWithVerification')
  tx = await authority.setUserRole(managerAddress, MANAGER_ROLE, true)
  await tx.wait()
  console.log('  tx:', tx.hash)

  // Teller gets MINTER_ROLE
  console.log('Assigning MINTER_ROLE to Teller')
  tx = await authority.setUserRole(tellerAddress, MINTER_ROLE, true)
  await tx.wait()
  console.log('  tx:', tx.hash)

  // Teller gets BURNER_ROLE
  console.log('Assigning BURNER_ROLE to Teller')
  tx = await authority.setUserRole(tellerAddress, BURNER_ROLE, true)
  await tx.wait()
  console.log('  tx:', tx.hash)

  // Strategist EOA gets UPDATE_EXCHANGE_RATE_ROLE
  console.log('Assigning UPDATE_EXCHANGE_RATE_ROLE to Strategist EOA')
  tx = await authority.setUserRole(strategistEOA, UPDATE_EXCHANGE_RATE_ROLE, true)
  await tx.wait()
  console.log('  tx:', tx.hash)

  // Strategist EOA gets STRATEGIST_ROLE
  console.log('Assigning STRATEGIST_ROLE to Strategist EOA')
  tx = await authority.setUserRole(strategistEOA, STRATEGIST_ROLE, true)
  await tx.wait()
  console.log('  tx:', tx.hash)

  // ==================== PUBLIC CAPABILITIES ====================
  // Functions callable by anyone (no role required)

  // Anyone can call deposit on Teller
  console.log('Setting public capability: Teller.deposit')
  tx = await authority.setPublicCapability(tellerAddress, DEPOSIT_SELECTOR, true)
  await tx.wait()
  console.log('  tx:', tx.hash)

  console.log('\nAll roles and capabilities configured successfully!')
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
