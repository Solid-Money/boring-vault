const fs = require('fs')
const { ethers, network } = require('hardhat')
const deployment = require('../deployment').load()
const { MERKL_DISTRIBUTOR, treeFilePath, findLeaf } = require('./leafs')

// Runs one strategy action for a stock vault through its Manager, as the strategist:
//   ACTION=deposit AMOUNT=<stock tokens>   approve and deposit into the SuperVault
//   ACTION=requestRedeem AMOUNT=<shares>   ask the SuperVault to redeem; Superform fulfils it later
//   ACTION=withdraw                        claim everything fulfilled so far
//   ACTION=cancel, then claimCancel        cancel a pending request, then take its shares back
//   ACTION=claimRewards                    claim the vault's unclaimed Merkl rewards
// Proofs come from the vault's tree file (config/setManageRoot.js writes it). Signs with PRIVATE_KEY,
// which must be the strategist's; STRATEGIST_UNLOCKED=1 sends from the strategist address unlocked
// on the node instead (fork dry run only).
const managerAddress = deployment.address('Manager')
const boringVault = deployment.address('BoringVault')
const { baseAsset, superVault, rewardTokens, strategist } = deployment.config

const erc20Abi = ['function approve(address,uint256)', 'function decimals() view returns (uint8)']
const superVaultAbi = [
  'function deposit(uint256,address)',
  'function requestRedeem(uint256,address,address)',
  'function cancelRedeemRequest(uint256,address)',
  'function claimCancelRedeemRequest(uint256,address,address)',
  'function withdraw(uint256,address,address)',
  'function decimals() view returns (uint8)',
  'function maxWithdraw(address) view returns (uint256)',
]
const merklAbi = ['function claim(address[],address[],uint256[],bytes32[][])']

async function main() {
  await deployment.check(ethers)
  // Hardhat only signs for PRIVATE_KEY, so the unlocked strategist talks to the node directly.
  const signer =
    process.env.STRATEGIST_UNLOCKED === '1'
      ? new ethers.providers.JsonRpcProvider(network.config.url).getSigner(strategist)
      : (await ethers.getSigners())[0]
  if ((await signer.getAddress()).toLowerCase() !== strategist.toLowerCase()) {
    throw new Error(`Signer ${await signer.getAddress()} is not the strategist ${strategist}`)
  }

  const { metadata, leafs } = JSON.parse(fs.readFileSync(treeFilePath(deployment), 'utf8'))
  const manager = await ethers.getContractAt(
    'src/base/Roles/ManagerWithMerkleVerification.sol:ManagerWithMerkleVerification',
    managerAddress,
    signer
  )
  const root = await manager.manageRoot(strategist)
  if (root !== metadata.ManageRoot) throw new Error(`The Manager's root ${root} is not the tree file's ${metadata.ManageRoot}`)

  const stock = new ethers.Contract(baseAsset, erc20Abi, signer)
  const vault = new ethers.Contract(superVault, superVaultAbi, signer)
  const merkl = new ethers.Contract(MERKL_DISTRIBUTOR, merklAbi, signer)
  const calls = [] // [contract, signature, args, address arguments the leaf binds]
  const action = process.env.ACTION
  const amount = process.env.AMOUNT

  if (action === 'deposit') {
    const assets = ethers.utils.parseUnits(amount, await stock.decimals())
    calls.push([stock, 'approve(address,uint256)', [superVault, assets], [superVault]])
    calls.push([vault, 'deposit(uint256,address)', [assets, boringVault], [boringVault]])
  } else if (action === 'requestRedeem') {
    const shares = ethers.utils.parseUnits(amount, await vault.decimals())
    calls.push([vault, 'requestRedeem(uint256,address,address)', [shares, boringVault, boringVault], [boringVault, boringVault]])
  } else if (action === 'withdraw') {
    const assets = await vault.maxWithdraw(boringVault)
    if (assets.isZero()) throw new Error('Nothing is claimable yet: Superform has not fulfilled a redeem request')
    calls.push([vault, 'withdraw(uint256,address,address)', [assets, boringVault, boringVault], [boringVault, boringVault]])
  } else if (action === 'cancel') {
    calls.push([vault, 'cancelRedeemRequest(uint256,address)', [0, boringVault], [boringVault]])
  } else if (action === 'claimCancel') {
    calls.push([vault, 'claimCancelRedeemRequest(uint256,address,address)', [0, boringVault, boringVault], [boringVault, boringVault]])
  } else if (action === 'claimRewards') {
    // Merkl amounts are cumulative: claim() pays the difference from what was claimed before.
    const res = await fetch(`https://api.merkl.xyz/v4/users/${boringVault}/rewards?chainId=8453`)
    if (!res.ok) throw new Error(`Merkl API: ${res.status} ${await res.text()}`)
    const rewards = (await res.json()).flatMap((c) => c.rewards)
    const due = rewardTokens
      .map((t) => rewards.find((r) => r.token.address.toLowerCase() === t.toLowerCase()))
      .filter((r) => r && ethers.BigNumber.from(r.amount).gt(r.claimed))
    if (due.length === 0) {
      console.log('No unclaimed Merkl rewards.')
      return
    }
    for (const r of due) console.log(`Claiming ${ethers.BigNumber.from(r.amount).sub(r.claimed)} of ${r.token.symbol} ${r.token.address}`)
    const tokens = due.map((r) => r.token.address)
    calls.push([
      merkl,
      'claim(address[],address[],uint256[],bytes32[][])',
      [tokens.map(() => boringVault), tokens, due.map((r) => r.amount), due.map((r) => r.proofs)],
      tokens.flatMap((t) => [boringVault, t]),
    ])
  } else {
    throw new Error('Set ACTION to deposit, requestRedeem, withdraw, cancel, claimCancel or claimRewards')
  }

  const proofs = []
  const decoders = []
  const targets = []
  const data = []
  for (const [contract, signature, args, addressArguments] of calls) {
    const l = findLeaf(leafs, contract.address, signature, addressArguments)
    proofs.push(l.Proof)
    decoders.push(l.DecoderAndSanitizerAddress)
    targets.push(contract.address)
    data.push(contract.interface.encodeFunctionData(signature, args))
    console.log(`${l.Description}: ${signature}`)
  }
  const tx = await manager.manageVaultWithMerkleVerification(proofs, decoders, targets, data, calls.map(() => 0))
  await tx.wait()
  console.log('  tx:', tx.hash)
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
