const fs = require('fs')
const { ethers, network } = require('hardhat')
const deployment = require('../deployment').load()
const {
  MERKL_DISTRIBUTOR,
  REWARD_CONVERSION,
  KYBER_SWAP,
  KYBER_SWAP_TYPES,
  kyberSwapArguments,
  treeFilePath,
  findLeaf,
} = require('./leafs')

// Runs one strategy action for a stock vault through its Manager, as the strategist:
//   ACTION=deposit AMOUNT=<stock tokens>   approve and deposit into the SuperVault
//   ACTION=requestRedeem AMOUNT=<shares>   ask the SuperVault to redeem; Superform fulfils it later
//   ACTION=withdraw                        claim everything fulfilled so far
//   ACTION=cancel, then claimCancel        cancel a pending request, then take its shares back
//   ACTION=claimRewards                    claim the vault's unclaimed Merkl rewards
// With the reward conversion in the root (a SwapDecoder):
//   ACTION=redeemUP [AMOUNT=<sUP>]         ask the sUP vault to redeem the vault's sUP (all by default) for UP
//   ACTION=claimUP                         claim the UP of every fulfilled sUP redeem
//   ACTION=cancelUP, then claimCancelUP    cancel a pending sUP redeem, then take the sUP back
//   ACTION=swap FROM=usdc|up [AMOUNT=<tokens>]
//                                          swap the vault's USDC or UP (all by default) into the stock
//                                          on KyberSwap; refuses a quote that loses more than
//                                          MAX_LOSS_BPS (300) of its dollar value
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
const rewardErc20Abi = [
  'function approve(address,uint256)',
  'function balanceOf(address) view returns (uint256)',
  'function decimals() view returns (uint8)',
  'function symbol() view returns (string)',
]
const kyberRouterAbi = [`function ${KYBER_SWAP} payable returns (uint256, uint256)`]
const KYBER_API = 'https://aggregator-api.kyberswap.com/base/api/v1'

// Builds a KyberSwap route of `amountIn` of `from` into the stock, paid to the vault, and checks it
// has the one shape the swap leaf allows before anything is sent.
async function buildKyberSwap(from, amountIn, to, slippageBips) {
  const headers = { 'x-client-id': 'solid', 'content-type': 'application/json' }
  const routes = await fetch(`${KYBER_API}/routes?tokenIn=${from}&tokenOut=${to}&amountIn=${amountIn}`, { headers })
  if (!routes.ok) throw new Error(`KyberSwap routes: ${routes.status} ${await routes.text()}`)
  const { routeSummary } = (await routes.json()).data
  const built = await fetch(`${KYBER_API}/route/build`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ routeSummary, sender: boringVault, recipient: boringVault, slippageTolerance: slippageBips }),
  })
  if (!built.ok) throw new Error(`KyberSwap build: ${built.status} ${await built.text()}`)
  const { data, routerAddress, amountOut } = (await built.json()).data
  if (routerAddress.toLowerCase() !== REWARD_CONVERSION.kyberRouter.toLowerCase()) {
    throw new Error(`KyberSwap built for router ${routerAddress}, not ${REWARD_CONVERSION.kyberRouter}`)
  }
  const router = new ethers.Contract(REWARD_CONVERSION.kyberRouter, kyberRouterAbi)
  const [execution] = router.interface.decodeFunctionData(KYBER_SWAP, data)
  const [executor, approveTarget, src, dst, receivers, recipient] = kyberSwapArguments(from, to, boringVault)
  const same = (a, b) => a.toLowerCase() === b.toLowerCase()
  const shapeOk =
    same(execution.callTarget, executor) &&
    same(execution.approveTarget, approveTarget) &&
    same(execution.desc.srcToken, src) &&
    same(execution.desc.dstToken, dst) &&
    execution.desc.srcReceivers.length === 1 &&
    same(execution.desc.srcReceivers[0], receivers[0]) &&
    same(execution.desc.dstReceiver, recipient)
  if (!shapeOk) throw new Error('KyberSwap built a route the swap leaf does not allow (executor, receivers or recipient differ)')
  return { router, data, routeSummary, amountOut, minOut: execution.desc.minReturnAmount }
}

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
  } else if (['redeemUP', 'claimUP', 'cancelUP', 'claimCancelUP', 'swap'].includes(action)) {
    if (!metadata.SwapDecoderAndSanitizerAddress) throw new Error('This vault has no reward conversion in its root yet')
    const upVault = new ethers.Contract(REWARD_CONVERSION.upVault, [...superVaultAbi, ...rewardErc20Abi], signer)
    if (action === 'redeemUP') {
      const shares = amount ? ethers.utils.parseUnits(amount, 18) : await upVault.balanceOf(boringVault)
      if (shares.isZero()) throw new Error('The vault holds no sUP')
      console.log(`Requesting the redeem of ${ethers.utils.formatUnits(shares, 18)} sUP`)
      calls.push([upVault, 'requestRedeem(uint256,address,address)', [shares, boringVault, boringVault], [boringVault, boringVault]])
    } else if (action === 'claimUP') {
      const assets = await upVault.maxWithdraw(boringVault)
      if (assets.isZero()) throw new Error('No sUP redeem is fulfilled yet')
      calls.push([upVault, 'withdraw(uint256,address,address)', [assets, boringVault, boringVault], [boringVault, boringVault]])
    } else if (action === 'cancelUP') {
      calls.push([upVault, 'cancelRedeemRequest(uint256,address)', [0, boringVault], [boringVault]])
    } else if (action === 'claimCancelUP') {
      calls.push([upVault, 'claimCancelRedeemRequest(uint256,address,address)', [0, boringVault, boringVault], [boringVault, boringVault]])
    } else {
      const from = { usdc: REWARD_CONVERSION.usdc, up: REWARD_CONVERSION.up }[(process.env.FROM || '').toLowerCase()]
      if (!from) throw new Error('Set FROM=usdc or FROM=up')
      const token = new ethers.Contract(from, rewardErc20Abi, signer)
      const amountIn = amount ? ethers.utils.parseUnits(amount, await token.decimals()) : await token.balanceOf(boringVault)
      if (amountIn.isZero()) throw new Error(`The vault holds no ${await token.symbol()}`)
      const swap = await buildKyberSwap(from, amountIn.toString(), baseAsset, Number(process.env.SLIPPAGE_BIPS || 50))
      const lossBips = 10000 - Math.round((Number(swap.routeSummary.amountOutUsd) / Number(swap.routeSummary.amountInUsd)) * 10000)
      console.log(
        `Swap ${ethers.utils.formatUnits(amountIn, await token.decimals())} ${await token.symbol()} ($${swap.routeSummary.amountInUsd}) ` +
          `for ${ethers.utils.formatUnits(swap.amountOut, await stock.decimals())} stock ($${swap.routeSummary.amountOutUsd}), ` +
          `minimum ${ethers.utils.formatUnits(swap.minOut, await stock.decimals())}, ${lossBips} bps lost`
      )
      if (lossBips > Number(process.env.MAX_LOSS_BPS || 300)) throw new Error(`The quote loses ${lossBips} bps, over MAX_LOSS_BPS`)
      calls.push([token, 'approve(address,uint256)', [REWARD_CONVERSION.kyberRouter, amountIn], [REWARD_CONVERSION.kyberRouter]])
      calls.push([
        swap.router.attach(REWARD_CONVERSION.kyberRouter),
        KYBER_SWAP,
        null, // calldata comes ready-built from KyberSwap
        kyberSwapArguments(from, baseAsset, boringVault),
        KYBER_SWAP_TYPES,
        swap.data,
      ])
    }
  } else {
    throw new Error(
      'Set ACTION to deposit, requestRedeem, withdraw, cancel, claimCancel, claimRewards, redeemUP, claimUP, cancelUP, claimCancelUP or swap'
    )
  }

  const proofs = []
  const decoders = []
  const targets = []
  const data = []
  for (const [contract, signature, args, addressArguments, types, rawData] of calls) {
    const l = findLeaf(leafs, contract.address, signature, addressArguments, types)
    proofs.push(l.Proof)
    decoders.push(l.DecoderAndSanitizerAddress)
    targets.push(contract.address)
    data.push(rawData || contract.interface.encodeFunctionData(signature, args))
    console.log(`${l.Description}: ${signature.split('(')[0]}`)
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
