const path = require('path')
const { MerkleTree } = require('merkletreejs')
const { utils } = require('ethers')

// Builds a stock vault's manage tree: the only calls its strategist may make through the Manager.
// Each leaf is keccak256(decoder, target, canSendValue, selector, packed address arguments), the
// digest ManagerWithMerkleVerification._verifyManageProof checks, and pairs are hashed sorted, as
// MerkleProofLib.verify expects.

const MERKL_DISTRIBUTOR = '0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae' // Merkl Distributor on Base

// Turning the Merkl rewards into more of the stock. USDC swaps straight into the stock. sUP is
// Superform's UP SuperVault, the same ERC-7540 contract as the stock SuperVaults: it is redeemed
// to UP first (selling sUP itself on a DEX loses most of its value), then UP swaps into the stock.
// Swaps go through KyberSwap's MetaAggregationRouterV2. On Base every route it builds has the
// executor as call target and as the one source receiver, no approve target, and the vault as
// receiver; the swap leaf pins all of those, so a route of any other shape fails the proof.
const REWARD_CONVERSION = {
  usdc: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
  upVault: '0x2c71f70e2Ec720AE061Ae7E0316fC9654d94f417', // sUP
  up: '0x5b2193fDc451C1f847bE09CA9d13A4Bf60f8c86B',
  kyberRouter: '0x6131B5fae19EA4f9D964eAc0408E4408b66337b5',
  kyberExecutor: '0x8F10B468b06c6FD214B65F87778827F7D113f996',
}
const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'

const DIGEST_COMPOSITION = [
  'Bytes20(DECODER_AND_SANITIZER_ADDRESS)',
  'Bytes20(TARGET_ADDRESS)',
  'Bytes1(CAN_SEND_VALUE)',
  'Bytes4(TARGET_FUNCTION_SELECTOR)',
  'Bytes{N*20}(ADDRESS_ARGUMENT_0,...,ADDRESS_ARGUMENT_N)',
]

// The decoder returns its addresses abi.encodePacked, so the leaf packs them the same way. Most
// arguments are single addresses; an address[] (the swap's source receivers) packs each element
// into a full 32-byte word, which is why `types` can say so.
function packArguments(addressArguments, types = addressArguments.map(() => 'address')) {
  return utils.solidityPack(types, addressArguments)
}

function leaf(decoder, description, target, signature, addressArguments, types) {
  const selector = utils.id(signature).slice(0, 10)
  const packed = packArguments(addressArguments, types)
  return {
    Description: description,
    FunctionSignature: signature,
    FunctionSelector: selector,
    TargetAddress: target,
    AddressArguments: addressArguments,
    ...(types && { AddressArgumentTypes: types }),
    CanSendValue: false,
    DecoderAndSanitizerAddress: decoder,
    PackedArgumentAddresses: packed,
    LeafDigest: utils.solidityKeccak256(
      ['address', 'address', 'bool', 'bytes4', 'bytes'],
      [decoder, target, false, selector, packed]
    ),
  }
}

const KYBER_SWAP =
  'swap((address,address,bytes,(address,address,address[],uint256[],address[],uint256[],address,uint256,uint256,uint256,bytes),bytes))'
// What KyberswapRouterDecoderAndSanitizer.swap returns: callTarget, approveTarget, srcToken,
// dstToken, srcReceivers, dstReceiver.
const KYBER_SWAP_TYPES = ['address', 'address', 'address', 'address', 'address[]', 'address']

function kyberSwapArguments(from, to, boringVault) {
  const { kyberExecutor } = REWARD_CONVERSION
  return [kyberExecutor, ZERO_ADDRESS, from, to, [kyberExecutor], boringVault]
}

// The reward conversion: redeem sUP to UP, then swap USDC and UP into the stock. Appended after
// the strategy leafs, so the tree a vault had before keeps every leaf it had.
function rewardConversionLeafs({ boringVault, decoder, swapDecoder, baseAsset }) {
  const bv = boringVault
  const { usdc, upVault, up, kyberRouter } = REWARD_CONVERSION
  return [
    leaf(decoder, 'Request to redeem sUP for UP', upVault, 'requestRedeem(uint256,address,address)', [bv, bv]),
    leaf(decoder, 'Claim the UP of a fulfilled sUP redeem', upVault, 'withdraw(uint256,address,address)', [bv, bv]),
    leaf(decoder, 'Cancel the pending sUP redeem', upVault, 'cancelRedeemRequest(uint256,address)', [bv]),
    leaf(decoder, 'Take back the sUP of a cancelled redeem', upVault, 'claimCancelRedeemRequest(uint256,address,address)', [bv, bv]),
    leaf(decoder, 'Approve KyberSwap to take USDC', usdc, 'approve(address,uint256)', [kyberRouter]),
    leaf(decoder, 'Approve KyberSwap to take UP', up, 'approve(address,uint256)', [kyberRouter]),
    leaf(swapDecoder, 'Swap USDC into the stock token on KyberSwap', kyberRouter, KYBER_SWAP, kyberSwapArguments(usdc, baseAsset, bv), KYBER_SWAP_TYPES),
    leaf(swapDecoder, 'Swap UP into the stock token on KyberSwap', kyberRouter, KYBER_SWAP, kyberSwapArguments(up, baseAsset, bv), KYBER_SWAP_TYPES),
  ]
}

// config: the vault record's config (baseAsset, superVault, rewardTokens). swapDecoder, the
// vault's KyberswapRouterDecoderAndSanitizer, adds the reward conversion; without it the tree is
// the strategy alone, as first deployed.
function stockLeafs({ boringVault, decoder, swapDecoder, config }) {
  const { baseAsset, superVault, rewardTokens } = config
  if (!baseAsset || !superVault || !rewardTokens) throw new Error('The record needs baseAsset, superVault and rewardTokens')
  const bv = boringVault
  const leafs = [
    leaf(decoder, 'Approve the SuperVault to take the stock token', baseAsset, 'approve(address,uint256)', [superVault]),
    leaf(decoder, 'Deposit the stock token into the SuperVault', superVault, 'deposit(uint256,address)', [bv]),
    leaf(decoder, 'Mint SuperVault shares with the stock token', superVault, 'mint(uint256,address)', [bv]),
    leaf(decoder, 'Request to redeem SuperVault shares', superVault, 'requestRedeem(uint256,address,address)', [bv, bv]),
    leaf(decoder, 'Cancel the pending redeem request', superVault, 'cancelRedeemRequest(uint256,address)', [bv]),
    leaf(decoder, 'Take back the shares of a cancelled redeem request', superVault, 'claimCancelRedeemRequest(uint256,address,address)', [bv, bv]),
    leaf(decoder, 'Claim a fulfilled redeem request by assets', superVault, 'withdraw(uint256,address,address)', [bv, bv]),
    leaf(decoder, 'Claim a fulfilled redeem request by shares', superVault, 'redeem(uint256,address,address)', [bv, bv]),
  ]
  // Merkl claims: the decoder returns every (user, token) pair, so each token set needs its own leaf.
  const claim = 'claim(address[],address[],uint256[],bytes32[][])'
  for (const token of rewardTokens) {
    leafs.push(leaf(decoder, `Claim Merkl rewards in ${token}`, MERKL_DISTRIBUTOR, claim, [bv, token]))
  }
  if (rewardTokens.length > 1) {
    leafs.push(leaf(decoder, 'Claim Merkl rewards in every reward token', MERKL_DISTRIBUTOR, claim, rewardTokens.flatMap((t) => [bv, t])))
  }
  if (swapDecoder) leafs.push(...rewardConversionLeafs({ boringVault: bv, decoder, swapDecoder, baseAsset }))
  return leafs
}

function buildTree(leafs) {
  const tree = new MerkleTree(leafs.map((l) => l.LeafDigest), utils.keccak256, { sortPairs: true })
  const root = tree.getHexRoot()
  for (const l of leafs) {
    l.Proof = tree.getHexProof(l.LeafDigest)
    if (!tree.verify(l.Proof, l.LeafDigest, root)) throw new Error(`Proof for "${l.Description}" does not verify`)
  }
  return root
}

// The file the strategist works from: every leaf with its proof, plus the addresses they bind to.
function treeFile({ deployment, decoder, swapDecoder, leafs, root }) {
  return {
    metadata: {
      BoringVaultAddress: deployment.address('BoringVault'),
      ManagerAddress: deployment.address('Manager'),
      AccountantAddress: deployment.address('Accountant'),
      DecoderAndSanitizerAddress: decoder,
      ...(swapDecoder && { SwapDecoderAndSanitizerAddress: swapDecoder }),
      Strategist: deployment.config.strategist,
      ManageRoot: root,
      LeafCount: leafs.length,
      DigestComposition: DIGEST_COMPOSITION,
    },
    leafs,
  }
}

// Where config/setManageRoot.js writes the tree file. A fork dry run keeps it next to its scratch
// record, never over the real one.
function treeFilePath(deployment) {
  if (process.env.DEPLOYMENT_FILE) return deployment.file.replace(/\.json$/, '-leafs.json')
  return path.join(__dirname, '..', '..', '..', 'leafs', 'Base', `${deployment.config.vaultTokenSymbol}StrategistLeafs.json`)
}

function findLeaf(leafs, target, signature, addressArguments, types) {
  const want = packArguments(addressArguments, types).toLowerCase()
  const found = leafs.find(
    (l) =>
      l.TargetAddress.toLowerCase() === target.toLowerCase() &&
      l.FunctionSignature === signature &&
      l.PackedArgumentAddresses.toLowerCase() === want
  )
  if (!found) throw new Error(`No leaf allows ${signature} on ${target} with ${addressArguments.join(', ')}`)
  return found
}

module.exports = {
  MERKL_DISTRIBUTOR,
  REWARD_CONVERSION,
  KYBER_SWAP,
  KYBER_SWAP_TYPES,
  kyberSwapArguments,
  stockLeafs,
  buildTree,
  treeFile,
  treeFilePath,
  findLeaf,
}
