require('dotenv').config()
const { keccak256 } = require('ethers/lib/utils')
const { ethers } = require('ethers')
const MerkleTree = require('merkletreejs').default

// === Config ===
const DECODER_AND_SANITIZER = '0x2d2f6D3bB89650B7CeB5E77Ad3dDb6Dc8BfCFCBF'
const UNISWAP_V3_MANAGER = '0xC36442b4a4522E871399CD717aBDD847Ab11FE88'
const VALUE_NON_ZERO = false

// === Interface matching your actual MintParams struct
const iface = new ethers.utils.Interface([
  'function mint((address token0,address token1,uint24 fee,int24 tickLower,int24 tickUpper,uint256 amount0Desired,uint256 amount1Desired,uint256 amount0Min,uint256 amount1Min,address recipient,uint256 deadline))',
])

// === Token and vault addresses
const USDC = '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48'
const WETH = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2'
const VAULT = '0x3C85d01b40a2152Be20862DEB331eCBa0FD6d691'

// === Realistic mint params
const mintParams = {
  token0: USDC,
  token1: WETH,
  fee: 3000,
  tickLower: -276330,
  tickUpper: -276270,
  amount0Desired: ethers.utils.parseUnits('0.0001', 18),
  amount1Desired: 0,
  amount0Min: 0,
  amount1Min: 0,
  recipient: VAULT,
  deadline: Math.floor(Date.now() / 1000) + 600,
}

const calldata = iface.encodeFunctionData('mint', [mintParams])
const selector = calldata.slice(0, 10)

// === Packed arguments used in sanitizer return
const mintPackedArgs = [USDC, WETH, VAULT]

// === Full allowlist for Merkle root generation
const allAllowed = [
  {
    selector: '0x88316456', // mint
    packedArgs: mintPackedArgs,
  },
  {
    selector: '0x219f5d17', // increaseLiquidity
    packedArgs: [WETH, USDC, VAULT, VAULT],
  },
  {
    selector: '0x0c49ccbe', // decreaseLiquidity
    packedArgs: [VAULT],
  },
  {
    selector: '0x4f1eb3d8', // collect
    packedArgs: [VAULT, VAULT],
  },
  {
    selector: '0x04e45aaf', // exactInput
    packedArgs: [USDC, VAULT],
  },
  {
    selector: '0x42966c68', // burn
    packedArgs: [VAULT],
  },
]

// === Encode leaves for Merkle tree
const leaves = allAllowed.map(({ selector, packedArgs }) => {
  const packed = ethers.utils.solidityPack(
    new Array(packedArgs.length).fill('address'),
    packedArgs
  )
  return keccak256(
    ethers.utils.solidityPack(
      ['address', 'address', 'bool', 'bytes4', 'bytes'],
      [
        DECODER_AND_SANITIZER,
        UNISWAP_V3_MANAGER,
        VALUE_NON_ZERO,
        selector,
        packed,
      ]
    )
  )
})

// === Construct the Merkle tree
const tree = new MerkleTree(leaves, keccak256, { sortPairs: true })
const root = tree.getHexRoot()

// === Get the proof for the mint() selector
const packedMintArgs = ethers.utils.solidityPack(
  new Array(mintPackedArgs.length).fill('address'),
  mintPackedArgs
)
const mintLeaf = keccak256(
  ethers.utils.solidityPack(
    ['address', 'address', 'bool', 'bytes4', 'bytes'],
    [
      DECODER_AND_SANITIZER,
      UNISWAP_V3_MANAGER,
      VALUE_NON_ZERO,
      selector,
      packedMintArgs,
    ]
  )
)
const proof = tree.getHexProof(mintLeaf)

// === Final Output
console.log('✅ Correct Merkle Root:\n', root)
console.log('\n📜 Use this proof array in your StrategyManagement.s.sol:')
console.log(JSON.stringify(proof, null, 2))
console.log('\n🧾 Calldata for mint():\n', calldata)
