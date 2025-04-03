const hre = require('hardhat')
const { ethers } = require('hardhat')

async function main() {
  console.log('🚀 Deploying Fuse infrastructure...')

  const MINTER_ROLE = 2
  const BURNER_ROLE = 3

  const [deployer] = await ethers.getSigners()
  console.log(`🔐 Deployer: ${deployer.address}`)

  // Config
  const ethereumVaultAddr = '0x242d74d15eF015D2138a23ab67b6a1278A6B535A' // Mainnet vault
  const strategistAddr = '0x70D1c611788aFF8228b5d845A5Dc95927022cF7c'// EOA
  const fuseWETH = '0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590'

  // ➕ Deploy dummy BoringVault
  console.log(
    '📦 Deploying dummy BoringVault on Fuse (constructor placeholder)...'
  )
  const BoringVault = await ethers.getContractFactory('BoringVault')
  const dummyVault = await BoringVault.deploy(
    deployer.address,
    'fWETH',
    'fWETH',
    18
  )

  await dummyVault.deployed()
  console.log(`✅ Dummy Vault deployed at: ${dummyVault.address}`)

  // ➕ Deploy Accountant
  console.log('🧮 Deploying Accountant...')
  const AccountantWithRateProviders = await ethers.getContractFactory(
    'AccountantWithRateProviders'
  )

  const payoutAddress = strategistAddr
  const startingExchangeRate = ethers.utils.parseEther('1.0')
  const baseAsset = fuseWETH
  const allowedChangeUpper = 1000 // 10%
  const allowedChangeLower = 1000
  const minimumUpdateDelay = 86400 // 1 day
  const managementFee = 0
  const performanceFee = 0

  const accountant = await AccountantWithRateProviders.deploy(
    deployer.address,
    dummyVault.address, // use dummy vault on Fuse
    payoutAddress,
    startingExchangeRate,
    baseAsset,
    allowedChangeUpper,
    allowedChangeLower,
    minimumUpdateDelay,
    managementFee,
    performanceFee
  )
  await accountant.deployed()
  console.log(`✅ Accountant deployed at: ${accountant.address}`)

  // ➕ Deploy Teller
  console.log('💵 Deploying Teller...')
  const TellerWithMultiAssetSupport = await ethers.getContractFactory(
    'TellerWithMultiAssetSupport'
  )

  const teller = await TellerWithMultiAssetSupport.deploy(
    deployer.address,
    dummyVault.address, // ETH vault is still where the mint/burn happens
    accountant.address,
    fuseWETH
  )
  await teller.deployed()
  console.log(`✅ Teller deployed at: ${teller.address}`)

  // ➕ Set up rate provider data
  console.log('⚙️ Setting rate provider data...')
  await accountant.setRateProviderData(
    fuseWETH,
    true,
    ethers.constants.AddressZero
  )

  console.log(`
======================= ✅ DEPLOYMENT SUMMARY =======================
Accountant:         ${accountant.address}
Teller:             ${teller.address}
Dummy Vault (Fuse): ${dummyVault.address}
====================================================================

🚨 IMPORTANT: On Ethereum, grant MINTER_ROLE & BURNER_ROLE to the Teller:
Vault:   ${ethereumVaultAddr}
Teller:  ${teller.address}
Roles:   MINTER_ROLE = ${MINTER_ROLE}, BURNER_ROLE = ${BURNER_ROLE}
`)
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('❌ Deployment failed:', error)
    process.exit(1)
  })
