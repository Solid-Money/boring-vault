const path = require('path')
const { MerkleTree } = require('merkletreejs')
const { utils } = require('ethers')

// Builds a stock vault's manage tree: the only calls its strategist may make through the Manager.
// Each leaf is keccak256(decoder, target, canSendValue, selector, packed address arguments), the
// digest ManagerWithMerkleVerification._verifyManageProof checks, and pairs are hashed sorted, as
// MerkleProofLib.verify expects.

const MERKL_DISTRIBUTOR = '0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae' // Merkl Distributor on Base

const DIGEST_COMPOSITION = [
  'Bytes20(DECODER_AND_SANITIZER_ADDRESS)',
  'Bytes20(TARGET_ADDRESS)',
  'Bytes1(CAN_SEND_VALUE)',
  'Bytes4(TARGET_FUNCTION_SELECTOR)',
  'Bytes{N*20}(ADDRESS_ARGUMENT_0,...,ADDRESS_ARGUMENT_N)',
]

function leaf(decoder, description, target, signature, addressArguments) {
  const selector = utils.id(signature).slice(0, 10)
  const packed = utils.solidityPack(addressArguments.map(() => 'address'), addressArguments)
  return {
    Description: description,
    FunctionSignature: signature,
    FunctionSelector: selector,
    TargetAddress: target,
    AddressArguments: addressArguments,
    CanSendValue: false,
    DecoderAndSanitizerAddress: decoder,
    PackedArgumentAddresses: packed,
    LeafDigest: utils.solidityKeccak256(
      ['address', 'address', 'bool', 'bytes4', 'bytes'],
      [decoder, target, false, selector, packed]
    ),
  }
}

// config: the vault record's config (baseAsset, superVault, rewardTokens).
function stockLeafs({ boringVault, decoder, config }) {
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
function treeFile({ deployment, decoder, leafs, root }) {
  return {
    metadata: {
      BoringVaultAddress: deployment.address('BoringVault'),
      ManagerAddress: deployment.address('Manager'),
      AccountantAddress: deployment.address('Accountant'),
      DecoderAndSanitizerAddress: decoder,
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

function findLeaf(leafs, target, signature, addressArguments) {
  const want = utils.solidityPack(addressArguments.map(() => 'address'), addressArguments).toLowerCase()
  const found = leafs.find(
    (l) =>
      l.TargetAddress.toLowerCase() === target.toLowerCase() &&
      l.FunctionSignature === signature &&
      l.PackedArgumentAddresses.toLowerCase() === want
  )
  if (!found) throw new Error(`No leaf allows ${signature} on ${target} with ${addressArguments.join(', ')}`)
  return found
}

module.exports = { MERKL_DISTRIBUTOR, stockLeafs, buildTree, treeFile, treeFilePath, findLeaf }
