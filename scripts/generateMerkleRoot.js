require('dotenv').config()
const { keccak256, defaultAbiCoder } = require('ethers/lib/utils')
const { ethers } = require('ethers')
const MerkleTree = require('merkletreejs').default

// --- Input config ---
const DECODER_AND_SANITIZER = '0x2d2f6D3bB89650B7CeB5E77Ad3dDb6Dc8BfCFCBF'
const UNISWAP_V3_MANAGER = '0xC36442b4a4522E871399CD717aBDD847Ab11FE88'

// Set of allowed function selectors + dummy address output
const allowed = [
  {
    selector: '0x3a3a6dc8', // mint
    packedArgs: [
      '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
      '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
      '0x3C85d01b40a2152Be20862DEB331eCBa0FD6d691',
    ], // token0, token1, recipient
  },
  {
    selector: '0x219f5d17', // increaseLiquidity
    packedArgs: [
      '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
      '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
      '0x3C85d01b40a2152Be20862DEB331eCBa0FD6d691',
      '0x3C85d01b40a2152Be20862DEB331eCBa0FD6d691',
    ], // operator, token0, token1, owner
  },
  {
    selector: '0x0c49ccbe', // decreaseLiquidity
    packedArgs: ['0x3C85d01b40a2152Be20862DEB331eCBa0FD6d691'],
  },
  {
    selector: '0x4f1eb3d8', // collect
    packedArgs: [
      '0x3C85d01b40a2152Be20862DEB331eCBa0FD6d691',
      '0x3C85d01b40a2152Be20862DEB331eCBa0FD6d691',
    ],
  },
  {
    selector: '0x04e45aaf', // exactInput
    packedArgs: [
      '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
      '0x3C85d01b40a2152Be20862DEB331eCBa0FD6d691',
    ],
  },
  {
    selector: '0x42966c68', // burn
    packedArgs: ['0x3C85d01b40a2152Be20862DEB331eCBa0FD6d691'],
  },
]

// --- Construct Merkle Tree ---
const leaves = allowed.map(({ selector, packedArgs }) => {
  const packedAddresses = ethers.utils.solidityPack(
    new Array(packedArgs.length).fill('address'),
    packedArgs
  )
  const leaf = keccak256(
    ethers.utils.solidityPack(
      ['address', 'address', 'bool', 'bytes4', 'bytes'],
      [
        DECODER_AND_SANITIZER,
        UNISWAP_V3_MANAGER,
        false,
        selector,
        packedAddresses,
      ]
    )
  )
  return leaf
})

const tree = new MerkleTree(leaves, keccak256, { sortPairs: true })

console.log('✅ Merkle Root:', tree.getHexRoot())
console.log('\n== Proof for each leaf ==')
leaves.forEach((leaf, i) => {
  console.log(`→ ${allowed[i].selector} proof:`)
  console.log(tree.getHexProof(leaf), '\n')
})

/*

✅ Merkle Root: 0x385c70e91efd653df05dc62fc03efe5d5ad405f18eaa832c7b7493ce5d884958

== Proof for each leaf ==
→ 0x3a3a6dc8 proof:
[
  '0x2165ab8142319d8e04619cc8c267ec04520dc836339da253e918bb9f3fe2e54d',
  '0xc2e3dfa46c061f592f7a2bc233b36d0b8c2fd839ba765a5c36ef75bfa5ebc558',
  '0xfd8b3ecaac0138d70e4b04ab50313c8c21555c17f6fc9b27aa9236ea184b7072'
] 

→ 0x219f5d17 proof:
[
  '0x4368f389632a5c03d36fd549694230f2534fd5b7a3be74d8f101a1fbb0a5f83a',
  '0xc2e3dfa46c061f592f7a2bc233b36d0b8c2fd839ba765a5c36ef75bfa5ebc558',
  '0xfd8b3ecaac0138d70e4b04ab50313c8c21555c17f6fc9b27aa9236ea184b7072'
] 

→ 0x0c49ccbe proof:
[
  '0x2f3830e5126a5f693da1a568f43e125bf0998c6eb5194197f3a62b1e158b5993',
  '0x21f804c61131822251f5f0aca1c542dc7487955e749e6a55080f24d451ccc854',
  '0xfd8b3ecaac0138d70e4b04ab50313c8c21555c17f6fc9b27aa9236ea184b7072'
] 

→ 0x4f1eb3d8 proof:
[
  '0x81394eabd8b459d930b88577af746cbe1bc500d0dba5826e25c5f5b6c54383a7',
  '0x21f804c61131822251f5f0aca1c542dc7487955e749e6a55080f24d451ccc854',
  '0xfd8b3ecaac0138d70e4b04ab50313c8c21555c17f6fc9b27aa9236ea184b7072'
] 

→ 0x04e45aaf proof:
[
  '0xecd824ce1269579bed4ded0387a5ddb38eb2f6b6f630cd4492f78f64cb67e944',
  '0x2138911e32e5ef0f4c7b3f565c2ef4202830a3fc366fd10c3be435ab924ee682'
] 

→ 0x42966c68 proof:
[
  '0xb3607db0d48e95982b7cb727f5780d4fe5850aca28d6a05058675c0545198186',
  '0x2138911e32e5ef0f4c7b3f565c2ef4202830a3fc366fd10c3be435ab924ee682'
] 

*/
