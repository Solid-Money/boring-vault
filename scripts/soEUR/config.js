const fs = require('fs')
const path = require('path')
const { ethers } = require('hardhat')

// soEUR on Ethereum: a sibling of the Base soEUR vault that only holds EURC moved over by the Base
// strategist through Circle's CrossChainTokenService (CCTPx). Shares are never minted on Ethereum, so
// there is no teller, accountant or queue: just a RolesAuthority, a BoringVault and a Manager.
// The SolidCrossChainTokenDecoderAndSanitizer goes through the CREATE2 factory, so it has one address
// on Base and Ethereum.
//
// Every script reads SOEUR_PROFILE (qa | prod) and refuses to run on any network but the one named.
// Fill the placeholders of that profile below first; a script throws on any it needs that is unset.
//
// Run order:
//   forge build <the four sources in CONTRACTS below>
//   SOEUR_PROFILE=qa npx hardhat run --no-compile scripts/soEUR/deployAll.js --network mainnet      (or 00-03 one by one)
//   SOEUR_PROFILE=qa npx hardhat run --no-compile scripts/soEUR/03_deployDecoder.js --network base
//   SOEUR_PROFILE=qa npx hardhat run --no-compile scripts/soEUR/04_configureRoles.js --network mainnet
//
// 04 sends the role changes while the deployer still owns the authority, then hands vault, manager
// and authority to the profile's owner. Once the owner holds the authority, a re-run writes the
// missing role changes as a Safe batch to deployments/safe-batches/ instead.
//
// After the backend computes the new merkle roots (approve + crossChainTransfer leaves on this
// decoder), the owner calls setManageRoot(strategist, root) on BOTH the Base soEUR manager and the
// new Ethereum manager. The Base vault pays the CCTPx fee in ETH (msg.value, ~0.0008 ETH per
// transfer with forwarding), so keep a little ETH in it; the Ethereum vault needs ETH for the way back.

// ethers v5 hardcodes a 1.5 gwei priority fee. Base's base fee is ~0.005 gwei, so that tip alone
// would be ~300x the real cost of every transaction; use the node's suggested tip instead.
// hardhat-ethers exposes the provider through a proxy that rejects writes, so patch its prototype.
const providerPrototype = Object.getPrototypeOf(ethers.provider)
const defaultGetFeeData = providerPrototype.getFeeData
providerPrototype.getFeeData = async function () {
  const feeData = await defaultGetFeeData.call(this)
  if (!feeData.lastBaseFeePerGas) return feeData
  const maxPriorityFeePerGas = ethers.BigNumber.from(await this.send('eth_maxPriorityFeePerGas', []))
  return {
    ...feeData,
    maxPriorityFeePerGas,
    maxFeePerGas: feeData.lastBaseFeePerGas.mul(2).add(maxPriorityFeePerGas),
  }
}

// Some Base RPCs (publicnode) return `to: ""` instead of null for contract creations. ethers v5
// rejects that when reading the transaction back, so a deploy that already landed throws before its
// address is recorded. Read an empty address as null.
const responseFormats = ethers.provider.formatter.formats
for (const [format, key] of [
  [responseFormats.transaction, 'to'],
  [responseFormats.receipt, 'to'],
  [responseFormats.receipt, 'contractAddress'],
]) {
  const formatAddress = format[key]
  format[key] = (value) => (value === '' ? null : formatAddress(value))
}

const MAINNET_CHAIN_ID = 1
const BASE_CHAIN_ID = 8453

// Folder names under deployments/addresses/.
const NETWORK_NAMES = {
  [MAINNET_CHAIN_ID]: 'Mainnet',
  [BASE_CHAIN_ID]: 'Base',
}

// null marks a placeholder; `required` throws until it is filled in.
const PROFILES = {
  qa: {
    base: {
      vault: '0xd094c7012357096b7DE164dc471630273A6fDa8C',
      manager: null, // QA Base soEUR ManagerWithMerkleVerification
    },
    mainnet: {
      owner: null, // receives the vault, manager and authority
      strategist: null, // QA strategist key, 0x78fD…4a0E
    },
  },
  prod: {
    base: {
      vault: '0x4f4B212aF8B5020399dde325e1Bc5B33b53DB70B',
      manager: null, // prod Base soEUR ManagerWithMerkleVerification
    },
    mainnet: {
      owner: null, // receives the vault, manager and authority
      strategist: null, // prod strategist key, 0x6f33…f9b5
    },
  },
}

const PROFILE = process.env.SOEUR_PROFILE
if (!PROFILES[PROFILE]) {
  throw new Error(`Set SOEUR_PROFILE to one of: ${Object.keys(PROFILES).join(', ')} (got ${PROFILE})`)
}
const profile = PROFILES[PROFILE]

function required(value, name) {
  if (!value) throw new Error(`${name} is not set for the ${PROFILE} profile in scripts/soEUR/config.js`)
  return ethers.utils.getAddress(value)
}

// Matches the Base soEUR vaults (name, symbol and decimals read on chain, 2026-10-19).
const vaultToken = {
  name: 'Solid EUR',
  symbol: 'soEUR',
  decimals: 6,
}

// Ethereum ManagerWithMerkleVerification constructor argument, as in scripts/MVP. No flash loans are used.
const balancerVault = '0xBA12222222228d8Ba445958a75a0704d566BF2C8'

// Circle CrossChainTokenService (CCTPx). The service and the EURC TokenManager have the same address on
// Base and Ethereum. The vault approves the TokenManager, not the service.
const cctpx = {
  service: '0x431871229103b780868f8C6BB820cd16ECf942BC',
  tokenManager: '0x8c27579e24F9f19D96724e19fC059dAcd1469e10',
  eurcTokenId: '0x6ca9e29fa53becc29becaf4a90b9ca7a995ad4d2234880da13ca38c657fb241c',
  crossChainTransferSelector: '0x780c5acf',
  domains: { [MAINNET_CHAIN_ID]: 0, [BASE_CHAIN_ID]: 6 },
  eurc: {
    [MAINNET_CHAIN_ID]: '0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c',
    [BASE_CHAIN_ID]: '0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42',
  },
}

// Same bytecode and salt on both chains give the decoder the same address on both.
const decoderDeploy = {
  create2Factory: '0x4e59b44847b379578588920cA78FbF26c0B4956C',
  salt: ethers.utils.id('SolidSoEUR.CrossChainTokenDecoderAndSanitizer.v1'),
}

// Role ids, matching scripts/MVP/baseConfig.js.
const ROLES = {
  MANAGER: 1,
  STRATEGIST: 7,
}

// Hardhat's compile runs solc 0.8.21 as WebAssembly here and runs out of memory on the whole src
// tree, so these scripts load Foundry's artifacts (`forge build`) and run with `hardhat run --no-compile`.
const CONTRACTS = {
  RolesAuthority: 'lib/solmate/src/auth/authorities/RolesAuthority.sol:RolesAuthority',
  BoringVault: 'src/base/BoringVault.sol:BoringVault',
  Manager: 'src/base/Roles/ManagerWithMerkleVerification.sol:ManagerWithMerkleVerification',
  Decoder:
    'src/base/DecodersAndSanitizers/Solid/SolidCrossChainTokenDecoderAndSanitizer.sol:SolidCrossChainTokenDecoderAndSanitizer',
}

const ROLES_AUTHORITY_ABI = [
  'function setRoleCapability(uint8 role, address target, bytes4 functionSig, bool enabled)',
  'function setUserRole(address user, uint8 role, bool enabled)',
  'function doesRoleHaveCapability(uint8 role, address target, bytes4 functionSig) view returns (bool)',
  'function doesUserHaveRole(address user, uint8 role) view returns (bool)',
]

const OWNED_ABI = [
  'function owner() view returns (address)',
  'function transferOwnership(address newOwner)',
  'function authority() view returns (address)',
  'function setAuthority(address newAuthority)',
]

async function requireNetwork(...chainIds) {
  const { chainId } = await ethers.provider.getNetwork()
  if (!chainIds.includes(chainId)) {
    throw new Error(`Expected chainId ${chainIds.join(' or ')}, connected to ${chainId}`)
  }
  return chainId
}

// Deployed addresses are recorded here by the deploy scripts and read back by the later ones.
function addressesFile(chainId) {
  return path.join(__dirname, '../../deployments/addresses', NETWORK_NAMES[chainId], `soEUR.${PROFILE}.json`)
}

function readDeployed(chainId) {
  const file = addressesFile(chainId)
  if (!fs.existsSync(file)) return {}
  return JSON.parse(fs.readFileSync(file, 'utf8')).contractAddresses
}

function requireDeployed(chainId, name) {
  const address = readDeployed(chainId)[name]
  if (!address) throw new Error(`${name} is not recorded in ${addressesFile(chainId)}; deploy it first`)
  return address
}

// Refuses to overwrite an existing entry, so a re-run cannot silently orphan a live contract.
function recordDeployed(chainId, name, address) {
  const file = addressesFile(chainId)
  const contractAddresses = readDeployed(chainId)
  if (contractAddresses[name]) {
    throw new Error(`${name} is already recorded at ${contractAddresses[name]}; remove it from ${file} to redeploy`)
  }
  contractAddresses[name] = address
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(
    file,
    JSON.stringify({ network: NETWORK_NAMES[chainId], chainId, profile: PROFILE, contractAddresses }, null, 2) + '\n',
  )
  console.log(`Recorded ${name} in ${path.relative(process.cwd(), file)}`)
}

// Base RPCs return flashblock preconfirmations, so a receipt can arrive before every node behind the
// endpoint has the block. Waiting for confirmations, and for new code to be visible, keeps each step
// on settled state.
const CONFIRMATIONS = 2

async function sendTx(txPromise) {
  const tx = await txPromise
  console.log(`  tx: ${tx.hash}`)
  return tx.wait(CONFIRMATIONS)
}

async function waitForCode(address) {
  for (let attempt = 0; attempt < 60; attempt++) {
    if ((await ethers.provider.getCode(address)) !== '0x') return
    await new Promise((resolve) => setTimeout(resolve, 2000))
  }
  throw new Error(`No code at ${address} after 2 minutes; if its deploy failed, remove it from the addresses file`)
}

/**
 * Deploys a contract and records it, or reuses the recorded one so an interrupted run resumes.
 * The address is recorded as soon as the deploy is broadcast, so a crash while waiting cannot
 * orphan it. `getArgs` is only called for a fresh deploy.
 */
async function deployOrResume(chainId, recordName, contractName, getArgs) {
  const recorded = readDeployed(chainId)[recordName]
  if (recorded) {
    console.log(`${recordName} already recorded at ${recorded}; reusing it`)
    await waitForCode(recorded)
    return getContractAt(contractName, recorded)
  }

  const factory = await getFactory(contractName)
  const contract = await factory.deploy(...(await getArgs()))
  console.log(`  tx: ${contract.deployTransaction.hash}`)
  recordDeployed(chainId, recordName, contract.address)
  await contract.deployTransaction.wait(CONFIRMATIONS)
  await waitForCode(contract.address)
  console.log(`${recordName} deployed at: ${contract.address}`)
  return contract
}

// Idempotent, so a resumed run finishes a contract whose setAuthority never landed.
async function ensureAuthority(contract, authority) {
  if ((await contract.authority()).toLowerCase() === authority.toLowerCase()) {
    console.log('Authority already set to:', authority)
    return
  }
  await sendTx(contract.setAuthority(authority))
  console.log('Authority set to:', authority)
}

// Foundry writes <out>/<File>.sol/<Name>.json, to artifacts/ or out/ depending on FOUNDRY_OUT; the
// newer of the two is used. The compilation target check guards against a same-named contract from
// another source file (flattened copies, forks) landing there.
function loadArtifact(contractName) {
  const [source, name] = CONTRACTS[contractName].split(':')
  const candidates = ['artifacts', 'out']
    .map((dir) => path.join(__dirname, '../..', dir, path.basename(source), `${name}.json`))
    .filter((file) => fs.existsSync(file))
    .sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs)
  if (candidates.length === 0) throw new Error(`No artifact for ${name}; run \`forge build ${source}\``)
  const file = candidates[0]
  const artifact = JSON.parse(fs.readFileSync(file, 'utf8'))
  const target = artifact.metadata && artifact.metadata.settings.compilationTarget
  if (!target || target[source] !== name) {
    throw new Error(`${file} was built from ${JSON.stringify(target)}, expected ${source}`)
  }
  return { abi: artifact.abi, bytecode: artifact.bytecode.object }
}

async function getFactory(contractName) {
  const [signer] = await ethers.getSigners()
  const { abi, bytecode } = loadArtifact(contractName)
  return new ethers.ContractFactory(abi, bytecode, signer)
}

async function getContractAt(contractName, address) {
  const [signer] = await ethers.getSigners()
  return new ethers.Contract(address, loadArtifact(contractName).abi, signer)
}

function sighash(contractName, signature) {
  return new ethers.utils.Interface(loadArtifact(contractName).abi).getSighash(signature)
}

/**
 * Writes a Safe Transaction Builder batch, after checking each call succeeds from the Safe.
 * @param txs [{ to, data, description }]
 */
async function writeSafeBatch({ fileName, name, safe, txs }) {
  const { chainId } = await ethers.provider.getNetwork()

  for (const tx of txs) {
    try {
      await ethers.provider.call({ from: safe, to: tx.to, data: tx.data })
    } catch (error) {
      throw new Error(`Simulation from ${safe} reverted: ${tx.description}\n${error.message}`)
    }
    console.log(`  ok  ${tx.description}`)
  }

  const batch = {
    version: '1.0',
    chainId: String(chainId),
    createdAt: Date.now(),
    meta: {
      name,
      description: `${txs.length} call(s) from ${safe}`,
      txBuilderVersion: '1.16.5',
    },
    transactions: txs.map((tx) => ({
      to: tx.to,
      value: '0',
      data: tx.data,
      contractMethod: null,
      contractInputsValues: null,
    })),
  }

  const file = path.join(__dirname, '../../deployments/safe-batches', fileName)
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(file, JSON.stringify(batch, null, 2) + '\n')
  console.log(`\nWrote ${txs.length} transaction(s) to ${path.relative(process.cwd(), file)}`)
  console.log(`Import it in the Safe Transaction Builder for ${safe} on chain ${chainId}.`)
}

module.exports = {
  MAINNET_CHAIN_ID,
  BASE_CHAIN_ID,
  PROFILE,
  profile,
  required,
  vaultToken,
  balancerVault,
  cctpx,
  decoderDeploy,
  ROLES,
  CONTRACTS,
  ROLES_AUTHORITY_ABI,
  OWNED_ABI,
  requireNetwork,
  addressesFile,
  readDeployed,
  requireDeployed,
  recordDeployed,
  sendTx,
  waitForCode,
  deployOrResume,
  ensureAuthority,
  loadArtifact,
  getFactory,
  getContractAt,
  sighash,
  writeSafeBatch,
}
