require('dotenv').config()
const { ethers } = require('ethers')

const provider = new ethers.providers.JsonRpcProvider(
  process.env.MAINNET_RPC_URL
)

// === Config ===
const UNISWAP_V3_MANAGER = '0xC36442b4a4522E871399CD717aBDD847Ab11FE88'
const USDC = '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48'
const WETH = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2'
const VAULT = '0x3C85d01b40a2152Be20862DEB331eCBa0FD6d691'

// === Desired mint parameters
const mintParams = {
  token0: USDC,
  token1: WETH,
  fee: 3000,
  tickLower: -276330,
  tickUpper: -276270,
  amount0Desired: ethers.utils.parseUnits('0.0001', 18), // WETH
  amount1Desired: 0,
  amount0Min: 0,
  amount1Min: 0,
  recipient: VAULT,
  deadline: Math.floor(Date.now() / 1000) + 600,
}

async function main() {
  const usdc = new ethers.Contract(
    USDC,
    [
      'function balanceOf(address) view returns (uint256)',
      'function allowance(address,address) view returns (uint256)',
    ],
    provider
  )
  const weth = new ethers.Contract(
    WETH,
    [
      'function balanceOf(address) view returns (uint256)',
      'function allowance(address,address) view returns (uint256)',
    ],
    provider
  )

  const vaultBalanceWETH = await weth.balanceOf(VAULT)
  const vaultAllowanceWETH = await weth.allowance(VAULT, UNISWAP_V3_MANAGER)

  const vaultBalanceUSDC = await usdc.balanceOf(VAULT)
  const vaultAllowanceUSDC = await usdc.allowance(VAULT, UNISWAP_V3_MANAGER)

  console.log('✅ Vault balances:')
  console.log('- WETH:', ethers.utils.formatEther(vaultBalanceWETH))
  console.log('- USDC:', ethers.utils.formatUnits(vaultBalanceUSDC, 6))

  console.log('\n✅ Allowances to Uniswap Manager:')
  console.log('- WETH:', ethers.utils.formatEther(vaultAllowanceWETH))
  console.log('- USDC:', ethers.utils.formatUnits(vaultAllowanceUSDC, 6))

  // Check tick spacing
  const tickSpacing = 60
  const validLower = mintParams.tickLower % tickSpacing === 0
  const validUpper = mintParams.tickUpper % tickSpacing === 0

  console.log('\n✅ Tick Spacing Check:')
  console.log('- tickLower valid?', validLower)
  console.log('- tickUpper valid?', validUpper)

  // === Simulate the mint
  const iface = new ethers.utils.Interface([
    'function mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256)) returns (uint256,uint128,uint256,uint256)',
  ])
  const manager = new ethers.Contract(
    UNISWAP_V3_MANAGER,
    iface.fragments,
    provider
  )

  console.log('\n🧪 Simulating UniswapV3 mint()...')

  try {
    const result = await manager.callStatic.mint(mintParams, { from: VAULT })
    console.log('✅ Mint simulation succeeded:')
    console.log('TokenId:', result[0].toString())
    console.log('Liquidity:', result[1].toString())
    console.log('Amount0 used (USDC):', result[2].toString())
    console.log('Amount1 used (WETH):', result[3].toString())
  } catch (err) {
    console.error('❌ Mint simulation failed:')
    console.error(err.reason || err.message)
  }
}

main()
