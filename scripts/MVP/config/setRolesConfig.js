const { ethers } = require('hardhat')
const deployment = require('../deployment').load()

// ==================== DEPLOYED ADDRESSES ====================
const authorityAddress = deployment.address('RolesAuthority')
const boringVaultAddress = deployment.address('BoringVault')
const accountantAddress = deployment.address('Accountant')
const tellerAddress = deployment.address('Teller')
const managerAddress = deployment.address('Manager')
const strategistEOA = deployment.config.strategist
const rateUpdater = deployment.config.rateUpdater // exchange-rate updater

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
  await deployment.check(ethers)
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

  // Rate updater gets UPDATE_EXCHANGE_RATE_ROLE (on PROD the strategist does not, matching the other prod vaults)
  console.log('Assigning UPDATE_EXCHANGE_RATE_ROLE to the rate updater')
  tx = await authority.setUserRole(rateUpdater, UPDATE_EXCHANGE_RATE_ROLE, true)
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
