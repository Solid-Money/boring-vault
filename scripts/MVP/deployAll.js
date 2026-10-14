const { ethers } = require('hardhat')

// ── Config ──────────────────────────────────────────────────────────────────
// The deployer owns every contract and the RolesAuthority while the config scripts run, so one
// key signs everything. config/transferOwnership.js hands all of it to the Base Safe at the end.
const ownerAddress = '0x607B5576B3C5a748C1Fe9d155a94f322E15F4628' // deployer
const payoutAddress = '0x3B694d634981Ace4B64a27c48bffe19f1447779B' // accountant fee recipient, same as soETH

const vaultTokenName = 'Solid EURC'
const vaultTokenSymbol = 'soEURC'
const vaultTokenDecimals = 6 // match EURC

const baseTokenAddress = '0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42' // EURC on Base
const startingExchangeRate = 1e6.toString() // 1 share = 1 EURC, in EURC decimals
const allowedExchangeRateChangeUpper = 10100 // same band as live soETH
const allowedExchangeRateChangeLower = 9900
const minimumUpdateDelayInSeconds = 1000
const platformFee = 0
const performanceFee = 1000

// soEURC is Base-only, so the teller is the plain TellerWithMultiAssetSupport (no bridging).
// Its nativeWrapper is only used for native ETH deposits, which stay disabled for soEURC.
const nativeWrapperAddress = '0x4200000000000000000000000000000000000006' // WETH on Base

const balancerVault = '0xBA12222222228d8Ba445958a75a0704d566BF2C8' // Balancer V2 Vault on Base

// ── Deploy ──────────────────────────────────────────────────────────────────
async function main() {
  const [deployer] = await ethers.getSigners()
  console.log('Deployer:', deployer.address)
  if (deployer.address.toLowerCase() !== ownerAddress.toLowerCase()) {
    throw new Error(`Signer ${deployer.address} is not ownerAddress ${ownerAddress}; set PRIVATE_KEY to the deployer key`)
  }
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

  await (await vault.setAuthority(authority.address, { gasLimit: 100000 })).wait()
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
    payoutAddress,
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

  await (await accountant.setAuthority(authority.address, { gasLimit: 100000 })).wait()
  console.log('Accountant authority updated')
  console.log('---')

  // 3. TellerWithMultiAssetSupport
  console.log('Deploying Teller...')
  const Teller = await ethers.getContractFactory(
    'src/base/Roles/TellerWithMultiAssetSupport.sol:TellerWithMultiAssetSupport'
  )
  const teller = await Teller.deploy(
    deployer.address,
    vault.address,
    accountant.address,
    nativeWrapperAddress // weth
  )
  await teller.deployed()
  console.log('Teller deployed at:', teller.address)

  await (await teller.setAuthority(authority.address, { gasLimit: 100000 })).wait()
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

  await (await manager.setAuthority(authority.address, { gasLimit: 100000 })).wait()
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
