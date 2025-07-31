require('dotenv').config()
const { ethers } = require('ethers')
const { Pool, Position } = require('@uniswap/v3-sdk')
const { Token } = require('@uniswap/sdk-core')
const JSBI = require('jsbi')

const depositContractABI = [
  'event Deposit(address indexed caller, uint256 amount);',
]

const boringVaultABI = [
  'function enter(address from, address asset, uint256 assetAmount, address to, uint256 shareAmount) external',
]

const uniswapV3PositionABI = [
  'function totalSupply() external view returns (uint256)',
  'function positions(uint256 tokenId) external view returns (uint96 nonce, address operator, address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, uint128 tokensOwed0, uint128 tokensOwed1)',
  'function balanceOf(address owner) external view returns (uint256)',
  'function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256)',
]

const erc20ABI = [
  'function decimals() external view returns (uint8)',
  'function balanceOf(address account) external view returns (uint256)',
]

const chainlinkABI = [
  'function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)',
  'function decimals() external view returns (uint8)',
]

const uniswapV3PoolABI = [
  'function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked)',
  'function token0() external view returns (address)',
  'function token1() external view returns (address)',
  'function fee() external view returns (uint24)',
]

const ethereumTeller = process.env.ETHEREUM_TELLER
const boringVaultAddress = process.env.VAULT_FUSE
const UNISWAP_POSITION_TOKEN_ID = process.env.UNISWAP_V3_POSITION

const ethereumProvider = new ethers.providers.JsonRpcProvider(
  process.env.MAINNET_RPC_URL
)
const fuseProvider = new ethers.providers.JsonRpcProvider(
  process.env.FUSE_RPC_URL
)

const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, fuseProvider)

const depositContract = new ethers.Contract(
  ethereumTeller,
  depositContractABI,
  ethereumProvider
)
const boringVault = new ethers.Contract(
  boringVaultAddress,
  boringVaultABI,
  wallet
)

// Add WETH and USDC addresses
const WETH_ADDRESS = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2'
const USDC_ADDRESS = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48'

// Add Chainlink ETH/USD Price Feed address
const ETH_USD_PRICE_FEED = '0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419'

// Uniswap V3 NonfungiblePositionManager address
const UNISWAP_V3_POSITION_MANAGER = '0xC36442b4a4522E871399CD717aBDD847Ab11FE88'

// Update contract initialization to use the correct Uniswap V3 contract address
const uniswapV3Position = new ethers.Contract(
  UNISWAP_V3_POSITION_MANAGER,
  uniswapV3PositionABI,
  ethereumProvider
)

// Add environment variable validation before initializing contracts
const validateEnvironmentVariables = () => {
  const requiredVars = [
    'ETHEREUM_TELLER',
    'VAULT_FUSE',
    'UNISWAP_V3_POSITION', // This should contain the token ID
    'MAINNET_RPC_URL',
    'FUSE_RPC_URL',
    'PRIVATE_KEY',
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
}

async function getEthUsdPrice() {
  try {
    const priceFeed = new ethers.Contract(
      ETH_USD_PRICE_FEED,
      chainlinkABI,
      ethereumProvider
    )

    const [, price] = await priceFeed.latestRoundData()
    const decimals = await priceFeed.decimals()

    // Convert the price to USD with proper decimal handling
    const ethUsdPrice = price.div(ethers.BigNumber.from(10).pow(decimals - 8))
    console.log(`Current ETH/USD price: $${ethUsdPrice.toNumber() / 1e8}`)

    return ethUsdPrice
  } catch (error) {
    console.error('Error fetching ETH/USD price:', error)
    // Return a fallback price if needed
    return ethers.BigNumber.from(2000 * 1e8) // Fallback $2000 USD with 8 decimals
  }
}

async function getPositionValue(ownerAddress) {
  try {
    // For testing, we'll use the specific position token ID instead of looking up
    // the user's positions, since the token might not be owned by the user in our test
    const tokenId = UNISWAP_POSITION_TOKEN_ID
    console.log(`Using position token ID: ${tokenId}`)

    // Get position details
    const position = await uniswapV3Position.positions(tokenId)
    console.log(`Position details retrieved for token ID ${tokenId}`)

    // Create contracts for token0 and token1
    const token0Contract = new ethers.Contract(
      position.token0,
      erc20ABI,
      ethereumProvider
    )
    const token1Contract = new ethers.Contract(
      position.token1,
      erc20ABI,
      ethereumProvider
    )

    // Get token decimals
    const token0Decimals = await token0Contract.decimals()
    const token1Decimals = await token1Contract.decimals()

    console.log(`Token0 (${position.token0}) decimals: ${token0Decimals}`)
    console.log(`Token1 (${position.token1}) decimals: ${token1Decimals}`)

    // Check which token is WETH and which is USDC
    const isToken0Weth =
      position.token0.toLowerCase() === WETH_ADDRESS.toLowerCase()
    const isToken1Weth =
      position.token1.toLowerCase() === WETH_ADDRESS.toLowerCase()

    // Get the pool address for this pair
    let poolAddress

    if (
      (isToken0Weth &&
        position.token1.toLowerCase() === USDC_ADDRESS.toLowerCase()) ||
      (isToken1Weth &&
        position.token0.toLowerCase() === USDC_ADDRESS.toLowerCase())
    ) {
      if (position.fee === 500) {
        poolAddress = '0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640' // 0.05% fee tier
      } else if (position.fee === 3000) {
        poolAddress = '0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8' // 0.3% fee tier
      } else if (position.fee === 10000) {
        poolAddress = '0x7BeA39867e4169DBe237d55C8242a8f2fcDcc387' // 1% fee tier
      }
    }

    if (!poolAddress) {
      console.log('Could not determine pool address, using fallback method')

      const wethValue = isToken0Weth
        ? position.liquidity.mul(ethers.utils.parseEther('0.0001'))
        : position.liquidity.mul(ethers.utils.parseEther('0.0001'))

      console.log(
        `Estimated position value using fallback: ${ethers.utils.formatEther(
          wethValue
        )} ETH`
      )
      return wethValue
    }

    const poolContract = new ethers.Contract(
      poolAddress,
      uniswapV3PoolABI,
      ethereumProvider
    )

    const slot0 = await poolContract.slot0()
    const sqrtPriceX96 = slot0.sqrtPriceX96.toString()
    const tick = slot0.tick

    console.log(`Current tick: ${tick}`)
    console.log(`Current sqrtPriceX96: ${sqrtPriceX96}`)

    const token0 = new Token(
      1,
      position.token0,
      token0Decimals,
      isToken0Weth ? 'WETH' : 'USDC',
      isToken0Weth ? 'Wrapped Ether' : 'USD Coin'
    )

    const token1 = new Token(
      1,
      position.token1,
      token1Decimals,
      isToken1Weth ? 'WETH' : 'USDC',
      isToken1Weth ? 'Wrapped Ether' : 'USD Coin'
    )

    try {
      const pool = new Pool(
        token0,
        token1,
        position.fee,
        JSBI.BigInt(sqrtPriceX96),
        position.liquidity.toString(),
        tick
      )

      const uniPosition = new Position({
        pool,
        liquidity: position.liquidity.toString(),
        tickLower: position.tickLower,
        tickUpper: position.tickUpper,
      })

      const amounts = uniPosition.mintAmounts
      const amount0 = ethers.BigNumber.from(amounts.amount0.toString())
      const amount1 = ethers.BigNumber.from(amounts.amount1.toString())

      console.log(
        `Token0 amount: ${ethers.utils.formatUnits(amount0, token0Decimals)}`
      )
      console.log(
        `Token1 amount: ${ethers.utils.formatUnits(amount1, token1Decimals)}`
      )

      let wethAmount
      let usdcAmount

      if (isToken0Weth) {
        wethAmount = amount0
        usdcAmount = amount1
      } else if (isToken1Weth) {
        wethAmount = amount1
        usdcAmount = amount0
      } else {
        console.log('Neither token is WETH, cannot calculate accurate value')
        return ethers.BigNumber.from(0)
      }

      const ethUsdPrice = await getEthUsdPrice()

      const usdcInEth = usdcAmount
        .mul(ethers.BigNumber.from(10).pow(18))
        .div(ethers.BigNumber.from(10).pow(6))
        .mul(ethers.BigNumber.from(10).pow(8))
        .div(ethUsdPrice)

      const totalEthValue = wethAmount.add(usdcInEth)

      console.log(
        `Position value in ETH: ${ethers.utils.formatEther(totalEthValue)} ETH`
      )
      return totalEthValue
    } catch (sdkError) {
      console.error('Error using Uniswap SDK:', sdkError)

      console.log('Using hardcoded position value as fallback')

      const fallbackValue = ethers.utils.parseEther('0.5')
      console.log(
        `Fallback position value: ${ethers.utils.formatEther(
          fallbackValue
        )} ETH`
      )

      return fallbackValue
    }
  } catch (error) {
    console.error('Error calculating position value:', error)

    const emergencyFallback = ethers.utils.parseEther('0.1')
    console.log(
      `Emergency fallback position value: ${ethers.utils.formatEther(
        emergencyFallback
      )} ETH`
    )
    return emergencyFallback
  }
}

// Update the manual deposit function to skip position value calculation
async function processManualDeposit() {
  console.log('Processing manual deposit...')

  const testSender = '0x70D1c611788aFF8228b5d845A5Dc95927022cF7c'
  const testAmount = ethers.BigNumber.from('900000000000000') // 0.0009 ETH

  console.log(
    `Processing deposit from ${testSender}, amount: ${ethers.utils.formatEther(
      testAmount
    )} ETH`
  )

  try {
    // Simplified approach: Just use a 1:1 ratio for deposits
    const sharesAmount = testAmount
    console.log(
      'Using 1:1 ratio for deposits (same amount of shares as deposit)'
    )
    console.log(`Share amount: ${ethers.utils.formatEther(sharesAmount)}`)

    console.log('Executing transaction on Fuse network:')
    console.log(`  From: ${testSender}`)
    console.log(`  Asset Amount: ${ethers.utils.formatEther(testAmount)} ETH`)
    console.log(`  Share Amount: ${ethers.utils.formatEther(sharesAmount)}`)

    // Send the transaction to the Fuse network
    //  function enter(address from, ERC20 asset, uint256 assetAmount, address to, uint256 shareAmount)
    const tx = await boringVault.enter(
      testSender,
      ethers.constants.AddressZero,
      0,
      testSender,
      sharesAmount
    )
    console.log(`Enter transaction sent on Fuse: ${tx.hash}`)

    // Wait for transaction confirmation
    const receipt = await tx.wait()
    console.log(
      `Transaction confirmed in block ${receipt.blockNumber} on Fuse network`
    )

    console.log('Manual deposit processed successfully')
  } catch (error) {
    console.error('Error in manual deposit processing:', error)
  }
}

async function testWithSpecificDeposit() {
  console.log('Running test with specific deposit event...')

  const testSender = '0x70D1c611788aFF8228b5d845A5Dc95927022cF7c'
  const testAmount = ethers.BigNumber.from('900000000000000') // 0.0009 ETH

  console.log(
    `Simulating deposit from ${testSender}, amount: ${ethers.utils.formatEther(
      testAmount
    )} ETH`
  )

  try {
    // Simplified approach: Just use a 1:1 ratio for deposits
    const sharesAmount = testAmount

    console.log(
      'Using 1:1 ratio for deposits (same amount of shares as deposit)'
    )

    // We still calculate position value for informational purposes
    const positionValue = await getPositionValue(testSender)
    console.log(
      `Position value: ${ethers.utils.formatEther(
        positionValue
      )} ETH equivalent (for reference only)`
    )

    console.log(
      `Calculated shares amount: ${ethers.utils.formatEther(sharesAmount)}`
    )

    console.log(
      'Test complete - transaction would be sent with the following parameters:'
    )
    console.log(`  From: ${testSender}`)
    console.log(`  Asset Amount: ${ethers.utils.formatEther(testAmount)} ETH`)
    console.log(`  Share Amount: ${ethers.utils.formatEther(sharesAmount)}`)
  } catch (error) {
    console.error('Error in test function:', error)
  }
}

// Update the main function to include the manual processing option
async function main() {
  validateEnvironmentVariables()

  // Update mode options to include 'manual' for manual deposit processing
  // TOGGLE MODE: Set to 'manual', 'listener', or 'test'
  const MODE = process.env.DEPOSIT_LISTENER_MODE

  if (MODE === 'manual') {
    // Process a manual deposit
    await processManualDeposit()
    console.log('Manual processing completed, exiting...')
    process.exit(0)
  } else if (MODE === 'test') {
    // Run the original test function (keep it for backwards compatibility)
    await testWithSpecificDeposit()
    console.log('Test completed, exiting...')
    process.exit(0)
  } else {
    console.log('Starting deposit listener...')
    console.log(
      'Listening for deposits on Ethereum and executing on Fuse network'
    )

    depositContract.on('Deposit', async (sender, amount, event) => {
      console.log(
        `Deposit detected from ${sender}, amount: ${ethers.utils.formatEther(
          amount
        )} ETH`
      )

      try {
        // Simplified approach: Just use a 1:1 ratio for deposits
        const sharesAmount = amount
        console.log(
          'Using 1:1 ratio for deposits (same amount of shares as deposit)'
        )
        console.log(`Share amount: ${ethers.utils.formatEther(sharesAmount)}`)

        console.log('Executing transaction on Fuse network:')
        console.log(`  From: ${sender}`)
        console.log(`  Asset Amount: ${ethers.utils.formatEther(amount)} ETH`)
        console.log(`  Share Amount: ${ethers.utils.formatEther(sharesAmount)}`)

        // Send the transaction to the Fuse network
        const tx = await boringVault.enter(
          sender,
          ethers.constants.AddressZero,
          0, // Using 0 for assetAmount as we're doing in manual mode
          sender,
          sharesAmount
        )
        console.log(`Enter transaction sent on Fuse: ${tx.hash}`)

        // Wait for transaction confirmation
        const receipt = await tx.wait()
        console.log(
          `Transaction confirmed in block ${receipt.blockNumber} on Fuse network`
        )
      } catch (error) {
        console.error('Error calling enter function on Fuse:', error)
      }
    })

    console.log('Listening for Deposit events on Ethereum...')
  }
}

process.on('SIGINT', () => {
  console.log('Shutting down listener...')
  process.exit(0)
})

main().catch((error) => {
  console.error('Error in main function:', error)
  process.exit(1)
})
