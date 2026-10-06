const { ethers } = require('hardhat')

// ── Config ──────────────────────────────────────────────────────────────────
const ownerAddress = '0x3B694d634981Ace4B64a27c48bffe19f1447779B'

const vaultTokenName = 'Solid ETH'
const vaultTokenSymbol = 'soETH'
const vaultTokenDecimals = 18

const baseTokenAddress = '0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590' // WETH on Fuse
const startingExchangeRate = 1e18.toString()
const allowedExchangeRateChangeUpper = 20000
const allowedExchangeRateChangeLower = 1
const minimumUpdateDelayInSeconds = 1000
const platformFee = 0
const performanceFee = 1000

const lzEndPointAddress = '0x1a44076050125825900e736c501f859c50fE728c'
const lzTokenAddress = ethers.constants.AddressZero

const balancerVault = '0xBA12222222228d8Ba445958a75a0704d566BF2C8'

// ── Deploy ──────────────────────────────────────────────────────────────────
async function main() {
  const [deployer] = await ethers.getSigners()
  console.log('Deployer:', deployer.address)
  console.log('---')

  // 0. RolesAuthority
  console.log('Deploying RolesAuthority...')
  const RolesAuthority = await ethers.getContractFactory(
    'src/fuse/FuseRolesAuthority.sol:FuseRolesAuthority'
  )
  const authority = await RolesAuthority.deploy(ownerAddress, ethers.constants.AddressZero)
  await authority.deployed()
  console.log('RolesAuthority deployed at:', authority.address)
  console.log('---')

  // 1. BoringVault
  console.log('Deploying BoringVault...')
  const BoringVault = await ethers.getContractFactory('src/base/BoringVault.sol:BoringVault')
  const vault = await BoringVault.deploy(
    deployer.address,
    vaultTokenName,
    vaultTokenSymbol,
    vaultTokenDecimals
  )
  await vault.deployed()
  console.log(`${vaultTokenName} Vault deployed at:`, vault.address)

  await vault.setAuthority(authority.address)
  console.log('Vault authority updated')
  console.log('---')

  // 2. AccountantWithRateProviders
  console.log('Deploying AccountantWithRateProviders...')
  const Accountant = await ethers.getContractFactory(
    'src/base/Roles/AccountantWithRateProviders.sol:AccountantWithRateProviders'
  )
  const accountant = await Accountant.deploy(
    deployer.address,
    vault.address,
    ownerAddress, // payoutAddress
    startingExchangeRate,
    baseTokenAddress,
    allowedExchangeRateChangeUpper,
    allowedExchangeRateChangeLower,
    minimumUpdateDelayInSeconds,
    platformFee,
    performanceFee
  )
  await accountant.deployed()
  console.log('Accountant deployed at:', accountant.address)

  await accountant.setAuthority(authority.address)
  console.log('Accountant authority updated')
  console.log('---')

  // 3. LayerZeroTeller
  console.log('Deploying LayerZero Teller...')
  const Teller = await ethers.getContractFactory(
    'src/base/Roles/CrossChain/Bridges/LayerZero/LayerZeroTeller.sol:LayerZeroTeller'
  )
  const teller = await Teller.deploy(
    deployer.address,
    vault.address,
    accountant.address,
    baseTokenAddress, // weth
    lzEndPointAddress,
    ownerAddress, // delegate
    lzTokenAddress
  )
  await teller.deployed()
  console.log('Teller deployed at:', teller.address)

  await teller.setAuthority(authority.address)
  console.log('Teller authority updated')
  console.log('---')

  // 4. ManagerWithMerkleVerification
  console.log('Deploying ManagerWithMerkleVerification...')
  const Manager = await ethers.getContractFactory(
    'src/base/Roles/ManagerWithMerkleVerification.sol:ManagerWithMerkleVerification'
  )
  const manager = await Manager.deploy(deployer.address, vault.address, balancerVault)
  await manager.deployed()
  console.log('Manager deployed at:', manager.address)

  await manager.setAuthority(authority.address)
  console.log('Manager authority updated')
  console.log('---')

  // ── Summary ─────────────────────────────────────────────────────────────
  console.log('\n=== Deployment Summary ===')
  console.log('RolesAuthority:', authority.address)
  console.log('BoringVault:   ', vault.address)
  console.log('Accountant:    ', accountant.address)
  console.log('Teller:        ', teller.address)
  console.log('Manager:       ', manager.address)
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
