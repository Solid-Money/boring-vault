require('dotenv').config()
const { ethers } = require('ethers')

const withdrawEventABI = [
  'event Withdraw(address indexed caller, uint256 shares);',
]

const boringVaultABI = [
  'function exit(address to, address asset, uint256 assetAmount, address from, uint256 shareAmount) external',
  'function totalSupply() external view returns (uint256)',
  'function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin) external returns (uint256)',
  'function bridgeAsset(address token, uint256 amount, address to, uint16 dstChainId) external payable returns (bytes32)',
  'function estimateBridgeFee(address token, uint256 amount, uint16 dstChainId) external view returns (uint256)',
  'function manage(address target, bytes calldata data, uint256 value) external returns (bytes memory)',
]

const erc20ABI = [
  'function approve(address spender, uint256 amount) external returns (bool)',
  'function balanceOf(address account) external view returns (uint256)',
  'function decimals() external view returns (uint8)',
  'function allowance(address owner, address spender) external view returns (uint256)',
  'function transfer(address to, uint256 amount) external returns (bool)',
]

const uniswapRouterABI = [
  'function swapExactTokensForTokens(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts)',
  'function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts)',
]

const layerZeroBridgeABI = [
  'function minDstGasLookup(uint16 dstChainId, uint16 packetType) external view returns (uint256)',
  'function estimateBridgeFee(bool useZro, bytes calldata adapterParams) external view returns (uint256 nativeFee, uint256 zroFee)',
  'function bridge(address token, uint256 amount, address to, tuple(address refundAddress, address zroPaymentAddress) calldata callParams, bytes calldata adapterParams) external payable returns (bytes32)',
]

// Contract addresses
const fuseTeller = process.env.FUSE_TELLER
const boringVaultAddress = process.env.VAULT_FUSE
const ethereumVaultAddress = process.env.VAULT
const BRIDGE_ADDRESS = '0x95f51f18212c6bcffb819fdb2035e5757954b7b9' // Layer Zero bridge address
const ETHEREUM_BRIDGE_ADDRESS = '0x95f51f18212c6bcffb819fdb2035e5757954b7b9' // Layer Zero bridge address on Ethereum
const UNISWAP_ROUTER = '0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D' // Uniswap router on Ethereum

// Chain IDs
const ETHEREUM_CHAIN_ID = 1 // Ethereum mainnet

// Token addresses
const WETH_ADDRESS_FUSE =
  process.env.WETH_FUSE || '0xa722c13135930332Eb3d749B2F0906559D2C5b99' // Fuse WETH
const WETH_ADDRESS_ETHEREUM = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2' // Ethereum WETH
const USDC_ADDRESS_ETHEREUM = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48' // Ethereum USDC

// Providers
const fuseProvider = new ethers.providers.JsonRpcProvider(
  process.env.FUSE_RPC_URL
)
const ethProvider = new ethers.providers.JsonRpcProvider(
  process.env.MAINNET_RPC_URL
)

// Wallet
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, fuseProvider)
const ethWallet = new ethers.Wallet(process.env.PRIVATE_KEY, ethProvider)

// Contracts
const fuseTellerContract = new ethers.Contract(
  fuseTeller,
  withdrawEventABI,
  fuseProvider
)
const fuseBoringVault = new ethers.Contract(
  boringVaultAddress,
  boringVaultABI,
  wallet
)
const ethereumBoringVault = new ethers.Contract(
  ethereumVaultAddress,
  boringVaultABI,
  ethWallet
)
const wethContract = new ethers.Contract(WETH_ADDRESS_FUSE, erc20ABI, wallet)
const wethEthereumContract = new ethers.Contract(
  WETH_ADDRESS_ETHEREUM,
  erc20ABI,
  ethWallet
)
const usdcEthereumContract = new ethers.Contract(
  USDC_ADDRESS_ETHEREUM,
  erc20ABI,
  ethWallet
)
const bridgeContract = new ethers.Contract(
  BRIDGE_ADDRESS,
  layerZeroBridgeABI,
  wallet
)
const ethereumBridgeContract = new ethers.Contract(
  ETHEREUM_BRIDGE_ADDRESS,
  layerZeroBridgeABI,
  ethWallet
)
const uniswapRouter = new ethers.Contract(
  UNISWAP_ROUTER,
  uniswapRouterABI,
  ethWallet // Using Ethereum wallet since Uniswap is on Ethereum
)

// Environment variable validation
const validateEnvironmentVariables = () => {
  const requiredVars = [
    'FUSE_TELLER',
    'VAULT_FUSE',
    'VAULT',
    'FUSE_RPC_URL',
    'MAINNET_RPC_URL',
    'PRIVATE_KEY',
    'WETH_FUSE',
  ]

  const missing = requiredVars.filter((varName) => !process.env[varName])

  if (missing.length > 0) {
    console.error('Error: Missing required environment variables:')
    missing.forEach((varName) => console.error(`  - ${varName}`))
    console.error(
      'Please check your .env file and ensure all required variables are set.'
    )
    process.exit(1)
  }

  console.log('Environment variables loaded:')
  console.log(`  FUSE_TELLER: ${process.env.FUSE_TELLER}`)
  console.log(`  VAULT_FUSE: ${process.env.VAULT_FUSE}`)
  console.log(`  VAULT: ${process.env.VAULT}`)
  console.log(`  WETH_FUSE: ${process.env.WETH_FUSE}`)
  console.log(`  USDC_ETHEREUM: ${USDC_ADDRESS_ETHEREUM} (default)`)
  console.log(`  UNISWAP_ROUTER: ${UNISWAP_ROUTER} (default)`)
  console.log(`  FUSE_RPC_URL: ${process.env.FUSE_RPC_URL}`)
  console.log(`  MAINNET_RPC_URL: ${process.env.MAINNET_RPC_URL}`)
  console.log(
    `  PRIVATE_KEY: ${process.env.PRIVATE_KEY ? '✓ (set)' : '✗ (not set)'}`
  )
}

// Helper function to serialize adapter params
function serializeAdapterParams(adapterParams) {
  return ethers.utils.solidityPack(
    ['uint16', 'uint256'],
    [1, adapterParams.gasLimit] // 1 = v1, followed by gas limit
  )
}

// The AdapterParams class
class AdapterParams {
  constructor(version, gasLimit) {
    this.version = version
    this.gasLimit = gasLimit
  }

  static forV1(gasLimit) {
    return new AdapterParams(1, gasLimit)
  }
}

// Function to check token balances on Ethereum
async function checkEthereumTokenBalances(address) {
  try {
    const wethBalance = await wethEthereumContract.balanceOf(address)
    const usdcBalance = await usdcEthereumContract.balanceOf(address)
    const usdcDecimals = await usdcEthereumContract.decimals()

    console.log(
      `WETH Balance on Ethereum: ${ethers.utils.formatEther(wethBalance)} WETH`
    )
    console.log(
      `USDC Balance on Ethereum: ${ethers.utils.formatUnits(
        usdcBalance,
        usdcDecimals
      )} USDC`
    )

    return {
      weth: wethBalance,
      usdc: usdcBalance,
      usdcDecimals,
    }
  } catch (error) {
    console.error('Error checking token balances on Ethereum:', error)
    return {
      weth: ethers.BigNumber.from(0),
      usdc: ethers.BigNumber.from(0),
      usdcDecimals: 6,
    }
  }
}

// Function to check token balances on Fuse
async function checkFuseTokenBalances(address) {
  try {
    const wethBalance = await wethContract.balanceOf(address)

    console.log(
      `WETH Balance on Fuse: ${ethers.utils.formatEther(wethBalance)} WETH`
    )

    return {
      weth: wethBalance,
    }
  } catch (error) {
    console.error('Error checking token balances on Fuse:', error)
    return {
      weth: ethers.BigNumber.from(0),
    }
  }
}

// Function to check if vault has given approval to Uniswap router
async function checkVaultUniswapApproval() {
  try {
    // This is just for monitoring purposes since we can't easily modify the vault's approvals
    const allowance = await usdcEthereumContract.allowance(
      ethereumVaultAddress,
      UNISWAP_ROUTER
    )
    console.log(
      `Vault's USDC allowance for Uniswap Router: ${ethers.utils.formatUnits(
        allowance,
        6
      )}`
    )
    return allowance
  } catch (error) {
    console.error('Error checking vault Uniswap approval:', error)
    return ethers.BigNumber.from(0)
  }
}

// Function to create approval calldata for vault to approve USDC to Uniswap router
function createApprovalCalldata(usdcAmount) {
  const usdcInterface = new ethers.utils.Interface([
    'function approve(address spender, uint256 amount) external returns (bool)',
  ])

  const approvalData = usdcInterface.encodeFunctionData('approve', [
    UNISWAP_ROUTER,
    usdcAmount,
  ])

  return {
    target: USDC_ADDRESS_ETHEREUM,
    data: approvalData,
    value: 0,
  }
}

// Function to create swap calldata for Uniswap
function createSwapCalldata(usdcAmount, minWethOutput, deadline) {
  const swapRouterInterface = new ethers.utils.Interface([
    'function swapExactTokensForTokens(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts)',
  ])

  const path = [USDC_ADDRESS_ETHEREUM, WETH_ADDRESS_ETHEREUM]

  const swapData = swapRouterInterface.encodeFunctionData(
    'swapExactTokensForTokens',
    [
      usdcAmount,
      minWethOutput,
      path,
      ethereumVaultAddress, // Send WETH back to vault
      deadline,
    ]
  )

  return {
    target: UNISWAP_ROUTER,
    data: swapData,
    value: 0,
  }
}

// Function to transfer WETH from vault to EOA using vault's manage function
async function transferWethFromVaultToEOA(amount) {
  try {
    console.log(
      `Transferring ${ethers.utils.formatEther(
        amount
      )} WETH from vault to EOA...`
    )

    // Check vault's WETH balance
    const vaultWethBalance = await wethEthereumContract.balanceOf(
      ethereumVaultAddress
    )
    console.log(
      `Vault WETH balance: ${ethers.utils.formatEther(vaultWethBalance)} WETH`
    )

    if (vaultWethBalance.lt(amount)) {
      console.log(
        `Vault doesn't have enough WETH. Requested: ${ethers.utils.formatEther(
          amount
        )}, Available: ${ethers.utils.formatEther(vaultWethBalance)}`
      )
      amount = vaultWethBalance
      console.log(
        `Adjusting amount to vault's available balance: ${ethers.utils.formatEther(
          amount
        )}`
      )
    }

    if (amount.isZero()) {
      console.log('No WETH to transfer')
      return null
    }

    // Create transfer calldata
    const wethInterface = new ethers.utils.Interface([
      'function transfer(address to, uint256 amount) external returns (bool)',
    ])

    const transferData = wethInterface.encodeFunctionData('transfer', [
      ethWallet.address, // Send to EOA wallet
      amount,
    ])

    const transferTx = {
      target: WETH_ADDRESS_ETHEREUM,
      data: transferData,
      value: 0,
    }

    // Execute transfer via vault.manage
    console.log(
      `Executing vault.manage for WETH transfer to ${ethWallet.address}...`
    )
    const manageTx = await ethereumBoringVault.manage(
      transferTx.target,
      transferTx.data,
      transferTx.value,
      {
        gasLimit: 300000,
      }
    )

    console.log(`Transaction sent: ${manageTx.hash}`)
    const receipt = await manageTx.wait()
    console.log(
      `Transaction status: ${receipt.status === 1 ? 'Success' : 'Failed'}`
    )
    console.log(`Gas used: ${receipt.gasUsed.toString()}`)

    // Verify the transfer succeeded
    const eoa_balance = await wethEthereumContract.balanceOf(ethWallet.address)
    console.log(
      `EOA WETH balance after transfer: ${ethers.utils.formatEther(
        eoa_balance
      )} WETH`
    )

    return receipt.status === 1 ? amount : ethers.BigNumber.from(0)
  } catch (error) {
    console.error('Error transferring WETH from vault to EOA:', error)
    throw error
  }
}

// Function for EOA to bridge WETH directly to recipient on Fuse
async function bridgeWethFromEOA(address, amount) {
  try {
    console.log(
      `Bridging ${ethers.utils.formatEther(
        amount
      )} WETH from EOA to ${address} on Fuse...`
    )

    // Check EOA's WETH balance
    const eoa_balance = await wethEthereumContract.balanceOf(ethWallet.address)
    console.log(
      `EOA WETH balance: ${ethers.utils.formatEther(eoa_balance)} WETH`
    )

    if (eoa_balance.lt(amount)) {
      console.log(
        `EOA doesn't have enough WETH. Requested: ${ethers.utils.formatEther(
          amount
        )}, Available: ${ethers.utils.formatEther(eoa_balance)}`
      )
      amount = eoa_balance
      console.log(
        `Adjusting amount to EOA's available balance: ${ethers.utils.formatEther(
          amount
        )}`
      )
    }

    if (amount.isZero()) {
      console.log('No WETH to bridge')
      return null
    }

    // Create approval transaction first (if needed)
    const allowance = await wethEthereumContract.allowance(
      ethWallet.address,
      ETHEREUM_BRIDGE_ADDRESS
    )

    console.log(
      `Current EOA WETH allowance for bridge: ${ethers.utils.formatEther(
        allowance
      )}`
    )

    if (allowance.lt(amount)) {
      console.log('Approving bridge to use EOA WETH...')
      const approveTx = await wethEthereumContract.approve(
        ETHEREUM_BRIDGE_ADDRESS,
        ethers.constants.MaxUint256
      )

      console.log(`Approval transaction sent: ${approveTx.hash}`)
      const approveReceipt = await approveTx.wait()
      console.log(
        `Approval status: ${approveReceipt.status === 1 ? 'Success' : 'Failed'}`
      )
    }

    // Estimate bridge fee
    const dstChainId = 138 // Fuse Chain ID on LayerZero

    // Create adapter params for fee estimation
    const dstGasLimit = 300000
    const adapterParams = ethers.utils.solidityPack(
      ['uint16', 'uint256'],
      [1, dstGasLimit]
    )

    // Estimate bridge fee
    const nativeFee = await ethereumBridgeContract.estimateBridgeFee(
      false,
      adapterParams
    )

    // Increase fee by 20% for safety
    const increasedNativeFee = nativeFee.nativeFee.mul(120).div(100)
    console.log(
      `Estimated bridge fee: ${ethers.utils.formatEther(
        increasedNativeFee
      )} ETH`
    )

    // Create bridge callParams structure
    const callParams = {
      refundAddress: ethWallet.address,
      zroPaymentAddress: ethers.constants.AddressZero,
    }

    // Execute the bridge directly from EOA
    console.log('Executing bridge transaction from EOA...')
    const bridgeTx = await ethereumBridgeContract.bridge(
      WETH_ADDRESS_ETHEREUM,
      amount,
      address,
      callParams,
      adapterParams,
      {
        value: increasedNativeFee,
        gasLimit: 500000,
      }
    )

    console.log(`Bridge transaction sent: ${bridgeTx.hash}`)
    const bridgeReceipt = await bridgeTx.wait()
    console.log(
      `Bridge status: ${bridgeReceipt.status === 1 ? 'Success' : 'Failed'}`
    )

    if (bridgeReceipt.status === 1) {
      console.log(
        `Successfully bridged ${ethers.utils.formatEther(
          amount
        )} WETH to ${address} on Fuse`
      )
      console.log(`Funds will arrive on Fuse chain (ID 138) shortly`)
    }

    return bridgeTx.hash
  } catch (error) {
    console.error('Error bridging WETH from EOA:', error)
    throw error
  }
}

// New function that combines vault transfer and EOA bridging
async function vaultBridgeWethToFuse(address, amount) {
  console.log(
    `Processing withdraw of ${ethers.utils.formatEther(
      amount
    )} WETH to ${address} on Fuse...`
  )

  // Step 1: Transfer WETH from vault to EOA
  const transferredAmount = await transferWethFromVaultToEOA(amount)

  if (!transferredAmount || transferredAmount.isZero()) {
    console.error('Failed to transfer WETH from vault to EOA')
    return null
  }

  // Step 2: Bridge WETH from EOA to recipient on Fuse
  return bridgeWethFromEOA(address, transferredAmount)
}

// Test function for Ethereum vault bridging WETH to Fuse (updated to use new approach)
async function testVaultBridgeWethToFuse() {
  try {
    console.log('Starting vault-to-EOA-to-Fuse bridge test...')

    // Check vault WETH balance on Ethereum
    const vaultWethBalance = await wethEthereumContract.balanceOf(
      ethereumVaultAddress
    )
    console.log(
      `Ethereum Vault WETH Balance: ${ethers.utils.formatEther(
        vaultWethBalance
      )} WETH`
    )

    if (vaultWethBalance.isZero()) {
      console.error('No WETH available in Ethereum vault for testing bridge')
      return
    }

    // Ask for destination and amount
    const testDestination = process.env.TEST_DESTINATION || wallet.address
    console.log(`Destination address on Fuse: ${testDestination}`)

    // Use a small amount for testing (0.01 WETH or 10% of vault's balance, whichever is smaller)
    const suggestedAmount = ethers.utils.parseEther('0.01')
    const tenPercentOfBalance = vaultWethBalance.mul(10).div(100)
    const testAmount = process.env.TEST_AMOUNT
      ? ethers.utils.parseEther(process.env.TEST_AMOUNT)
      : suggestedAmount.lt(tenPercentOfBalance)
      ? suggestedAmount
      : tenPercentOfBalance

    // Make sure we don't try to bridge more than the vault has
    const bridgeAmount = testAmount.gt(vaultWethBalance)
      ? vaultWethBalance
      : testAmount

    console.log(
      `Bridging ${ethers.utils.formatEther(
        bridgeAmount
      )} WETH from Ethereum vault to ${testDestination} on Fuse`
    )

    // Execute bridge using new approach
    const bridgeTxHash = await vaultBridgeWethToFuse(
      testDestination,
      bridgeAmount
    )

    if (bridgeTxHash) {
      console.log(`Bridge test successful! Transaction: ${bridgeTxHash}`)
    } else {
      console.log('Bridge test failed - no transaction hash returned')
    }

    return bridgeTxHash
  } catch (error) {
    console.error('Error in bridge test function:', error)
  }
}

// Main function
async function main() {
  validateEnvironmentVariables()

  // TOGGLE MODE: set to 'manual', 'listener', 'test-vault-bridge', or 'test-vault-swap'
  const MODE = 'test-vault-bridge'

  if (MODE === 'manual') {
    await processManualWithdraw()
    console.log('Manual processing completed, exiting...')
    process.exit(0)
  } else if (MODE === 'test-vault-bridge') {
    console.log('Running vault bridge test mode...')
    await testVaultBridgeWethToFuse()
    console.log('Vault bridge test completed, exiting...')
    process.exit(0)
  } else if (MODE === 'test-vault-swap') {
    console.log('Running vault swap test mode...')
    await testVaultSwapUsdcToWeth()
    console.log('Vault swap test completed, exiting...')
    process.exit(0)
  } else {
    console.log('Starting withdraw listener...')
    console.log(
      'Listening for withdraws on Fuse network and bridging assets through Ethereum vault'
    )

    fuseTellerContract.on('Withdraw', async (caller, shares, event) => {
      console.log(
        `Withdraw detected from ${caller}, shares: ${ethers.utils.formatEther(
          shares
        )}`
      )

      try {
        const totalSupply = await fuseBoringVault.totalSupply()
        console.log(
          `Total supply: ${ethers.utils.formatEther(totalSupply)} shares`
        )

        const positionValue = await getPositionValue()

        const withdrawPercentage = totalSupply.gt(0)
          ? shares
              .mul(ethers.BigNumber.from(10000))
              .div(totalSupply)
              .toNumber() / 10000
          : 0
        console.log(`Withdraw percentage: ${withdrawPercentage * 100}%`)

        const withdrawValue = positionValue
          .mul(ethers.BigNumber.from(Math.floor(withdrawPercentage * 10000)))
          .div(10000)
        console.log(
          `Withdrawing ${ethers.utils.formatEther(
            withdrawValue
          )} ETH worth of assets`
        )

        console.log('Executing exit transaction on Fuse network:')
        console.log(`  To: ${caller}`)
        console.log(`  Share Amount: ${ethers.utils.formatEther(shares)}`)

        const exitTx = await fuseBoringVault.exit(
          wallet.address,
          ethers.constants.AddressZero,
          0,
          caller,
          shares
        )
        console.log(`Exit transaction sent on Fuse: ${exitTx.hash}`)

        const receipt = await exitTx.wait()
        console.log(
          `Exit transaction confirmed in block ${receipt.blockNumber}`
        )

        try {
          const wethAmount = withdrawValue
          console.log(
            `WETH amount to bridge: ${ethers.utils.formatEther(wethAmount)}`
          )

          const bridgeTx = await vaultBridgeWethToFuse(caller, wethAmount)
          console.log(
            `WETH successfully bridged to ${caller} on Fuse. Transaction: ${bridgeTx}`
          )
        } catch (bridgeError) {
          console.error('Error during bridging:', bridgeError)
        }
      } catch (error) {
        console.error('Error processing withdraw:', error)
      }
    })

    console.log('Listening for Withdraw events on Fuse...')
  }
}

process.on('SIGINT', () => {
  console.log('Shutting down withdraw listener...')
  process.exit(0)
})

main().catch((error) => {
  console.error('Error in main function:', error)
  process.exit(1)
})
