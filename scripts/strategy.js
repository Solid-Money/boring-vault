const dotenv = require('dotenv')
const { ethers } = require('ethers')
const IWETH9 = require('@uniswap/v3-periphery/artifacts/contracts/interfaces/external/IWETH9.sol/IWETH9.json')
const ISwapRouter = require('@uniswap/v3-periphery/artifacts/contracts/interfaces/ISwapRouter.sol/ISwapRouter.json')
const IUniswapV3Pool = require('@uniswap/v3-core/artifacts/contracts/interfaces/IUniswapV3Pool.sol/IUniswapV3Pool.json')
const INonfungiblePositionManager = require('@uniswap/v3-periphery/artifacts/contracts/interfaces/INonfungiblePositionManager.sol/INonfungiblePositionManager.json')
const IUniswapV3Factory = require('@uniswap/v3-core/artifacts/contracts/interfaces/IUniswapV3Factory.sol/IUniswapV3Factory.json')

dotenv.config()

// Constants
const USDC_ADDRESS = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48'
const UNISWAP_V3_FACTORY = '0x1F98431c8aD98523631AE4a59f267346ea31F984'
const POSITION_MANAGER_ADDRESS = '0xC36442b4a4522E871399CD717aBDD847Ab11FE88'
const SWAP_ROUTER_ADDRESS = '0xE592427A0AEce92De3Edee1F18E0157C05861564'
const POOL_FEE = 3000 // 0.3%
const WIDTH_PERCENTAGE = 1 // Ultra narrow range for tiny amounts
const DEADLINE = 3600 // 1 hour

// Environment variables
const ENV = {
  MAINNET_RPC_URL: process.env.MAINNET_RPC_URL,
  PRIVATE_KEY: process.env.PRIVATE_KEY,
  VAULT: process.env.VAULT,
  WETH: process.env.WETH,
}

// Helper functions
function getDeadline() {
  return Math.floor(Date.now() / 1000) + DEADLINE
}

function logError(error) {
  console.error('Error executing strategy:', error.message || error)
  if (error.stack) console.error(error.stack)
}

function getContract(address, abi, provider) {
  return new ethers.Contract(address, abi, provider)
}

/**
 * Calculate optimal tick range based on amount
 */
async function calculateTickRange(provider, poolAddress, wethAmount) {
  const pool = getContract(poolAddress, IUniswapV3Pool.abi, provider)
  const slot0 = await pool.slot0()
  const currentTick = slot0.tick
  const tickSpacing = await pool.tickSpacing()

  console.log(`Current tick: ${currentTick}, Tick spacing: ${tickSpacing}`)

  // Use single tick spacing for small amounts
  const wethAmountEther = ethers.utils.formatEther(wethAmount || '0')
  const isMicroAmount = parseFloat(wethAmountEther) < 0.001
  const tickDistance = isMicroAmount ? tickSpacing : Math.floor(tickSpacing * 3)

  if (isMicroAmount) {
    console.log(`Small amount (${wethAmountEther} WETH). Using tighter range.`)
  }

  const tickLower = Math.floor(currentTick / tickSpacing) * tickSpacing
  const tickUpper = tickLower + tickDistance

  console.log(
    `Tick range: ${tickLower} to ${tickUpper} (${tickUpper - tickLower} ticks)`
  )
  return { tickLower, tickUpper, currentTick }
}

/**
 * Get WETH-USDC pool address
 */
async function getPoolAddress(provider, wethAddress) {
  const factory = getContract(
    UNISWAP_V3_FACTORY,
    IUniswapV3Factory.abi,
    provider
  )

  // Order tokens by address (required by Uniswap)
  const token0 =
    wethAddress.toLowerCase() < USDC_ADDRESS.toLowerCase()
      ? wethAddress
      : USDC_ADDRESS
  const token1 =
    wethAddress.toLowerCase() < USDC_ADDRESS.toLowerCase()
      ? USDC_ADDRESS
      : wethAddress

  const poolAddress = await factory.getPool(token0, token1, POOL_FEE)
  if (poolAddress === ethers.constants.AddressZero) {
    throw new Error(`No pool found for WETH-USDC with fee ${POOL_FEE}`)
  }

  console.log(`Found WETH-USDC pool at address: ${poolAddress}`)
  return poolAddress
}

/**
 * Get token balances from vault
 */
async function getVaultBalances(provider, vaultAddress, wethAddress) {
  const weth = getContract(wethAddress, IWETH9.abi, provider)
  const wethBalance = await weth.balanceOf(vaultAddress)

  const usdc = new ethers.Contract(
    USDC_ADDRESS,
    ['function balanceOf(address) external view returns (uint256)'],
    provider
  )
  const usdcBalance = await usdc.balanceOf(vaultAddress)

  console.log(
    `Vault balances: ${ethers.utils.formatEther(wethBalance)} WETH, ${
      usdcBalance / 1e6
    } USDC`
  )
  return { wethBalance, usdcBalance }
}

/**
 * Create swap calldata for vault
 */
function createSwapCalldata(vaultAddress, wethAmount) {
  const halfWeth = wethAmount.div(2).mul(98).div(100)

  const wethInterface = new ethers.utils.Interface(IWETH9.abi)
  const approveData = wethInterface.encodeFunctionData('approve', [
    SWAP_ROUTER_ADDRESS,
    halfWeth,
  ])

  const swapRouterInterface = new ethers.utils.Interface(ISwapRouter.abi)
  const swapParams = {
    tokenIn: ENV.WETH,
    tokenOut: USDC_ADDRESS,
    fee: POOL_FEE,
    recipient: vaultAddress,
    deadline: getDeadline(),
    amountIn: halfWeth,
    amountOutMinimum: 0,
    sqrtPriceLimitX96: 0,
  }

  const swapData = swapRouterInterface.encodeFunctionData('exactInputSingle', [
    swapParams,
  ])

  return [
    { target: ENV.WETH, data: approveData, value: 0 },
    { target: SWAP_ROUTER_ADDRESS, data: swapData, value: 0 },
  ]
}

/**
 * Create position calldata for vault
 */
function createPositionCalldata(
  vaultAddress,
  wethBalance,
  usdcBalance,
  tickLower,
  tickUpper
) {
  // Approvals
  const wethInterface = new ethers.utils.Interface(IWETH9.abi)
  const usdcInterface = new ethers.utils.Interface([
    'function approve(address, uint256) returns (bool)',
  ])
  const positionInterface = new ethers.utils.Interface(
    INonfungiblePositionManager.abi
  )

  const wethApproveData = wethInterface.encodeFunctionData('approve', [
    POSITION_MANAGER_ADDRESS,
    wethBalance,
  ])
  const usdcApproveData = usdcInterface.encodeFunctionData('approve', [
    POSITION_MANAGER_ADDRESS,
    usdcBalance,
  ])

  // Position parameters
  const mintParams = {
    token0: USDC_ADDRESS,
    token1: ENV.WETH,
    fee: POOL_FEE,
    tickLower,
    tickUpper,
    amount0Desired: usdcBalance,
    amount1Desired: wethBalance,
    amount0Min: 0,
    amount1Min: 0,
    recipient: vaultAddress,
    deadline: getDeadline(),
  }

  const mintData = positionInterface.encodeFunctionData('mint', [mintParams])

  return [
    { target: ENV.WETH, data: wethApproveData, value: 0 },
    { target: USDC_ADDRESS, data: usdcApproveData, value: 0 },
    { target: POSITION_MANAGER_ADDRESS, data: mintData, value: 0 },
  ]
}

/**
 * Execute vault management call
 */
async function executeVaultCall(signer, vaultAddress, calldata) {
  const vault = new ethers.Contract(
    vaultAddress,
    ['function manage(address, bytes, uint256) returns (bytes)'],
    signer
  )

  const receipts = []
  for (const call of calldata) {
    console.log(`Calling vault.manage for target: ${call.target}`)
    const tx = await vault.manage(call.target, call.data, call.value, {
      gasLimit: 3000000,
    })
    console.log(`Transaction sent: ${tx.hash}`)
    const receipt = await tx.wait()
    console.log(
      `Confirmed: ${
        receipt.transactionHash
      }, Gas used: ${receipt.gasUsed.toString()}`
    )
    receipts.push(receipt)
  }
  return receipts
}

/**
 * Main deposit function
 */
async function deposit(provider, signer, vaultAddress) {
  if (!vaultAddress || !ENV.WETH) {
    throw new Error('Vault address and WETH address are required')
  }

  // Initialize
  const poolAddress = await getPoolAddress(provider, ENV.WETH)
  const { wethBalance } = await getVaultBalances(
    provider,
    vaultAddress,
    ENV.WETH
  )

  if (wethBalance.eq(0)) {
    throw new Error('Vault has no WETH balance')
  }

  console.log(
    `Working with ${ethers.utils.formatEther(wethBalance)} WETH in the vault`
  )

  // Step 1: Swap half WETH to USDC
  console.log(`Step 1: Swapping half WETH to USDC...`)
  const swapCalldata = createSwapCalldata(vaultAddress, wethBalance)
  await executeVaultCall(signer, vaultAddress, swapCalldata)

  // Step 2: Get updated balances
  const { wethBalance: remainingWeth, usdcBalance } = await getVaultBalances(
    provider,
    vaultAddress,
    ENV.WETH
  )

  // Step 3: Calculate position range
  const tickRange = await calculateTickRange(
    provider,
    poolAddress,
    remainingWeth
  )

  // Step 4: Create balanced position
  console.log(`Step 4: Creating balanced position...`)
  const positionCalldata = createPositionCalldata(
    vaultAddress,
    remainingWeth,
    usdcBalance,
    tickRange.tickLower,
    tickRange.tickUpper
  )

  return executeVaultCall(signer, vaultAddress, positionCalldata)
}

/**
 * Main function
 */
async function main() {
  // Setup
  const provider = new ethers.providers.JsonRpcProvider(ENV.MAINNET_RPC_URL)
  const signer = new ethers.Wallet(ENV.PRIVATE_KEY, provider)
  const vaultAddress = ENV.VAULT

  console.log(
    `Using vault: ${vaultAddress}, Signer: ${await signer.getAddress()}`
  )

  try {
    await deposit(provider, signer, vaultAddress)
    console.log('Deposit completed successfully')
  } catch (error) {
    logError(error)
    if (error.error)
      console.error('Detailed error:', JSON.stringify(error.error, null, 2))
    process.exit(1)
  }
}

// Run main if executed directly
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch(() => process.exit(1))
}
