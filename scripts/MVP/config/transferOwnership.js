const { ethers } = require('hardhat')

// ==================== NEW OWNER ====================
// The soETH multisig (3-of-4 on Ethereum). On Base it must first be recreated at the same address
// and then have its signers changed to match Ethereum: a fresh recreation comes up with the Safe's
// original 2024 signer set. The guard in main() refuses to hand anything over until that is done.
const newOwner = '0x6B26fAF3AD822695127B29ad242ac4B33D336F42'
const expectedSafeOwners = [
    '0x26F9A59F0F0e92e8a8d6f835d57657a3a3b51103',
    '0x2B30BD61C63DA8E528935A8589866D0509c39a50',
    '0x3B694d634981Ace4B64a27c48bffe19f1447779B',
    '0x63A61a31F087295a2b3fbE6F546913Ccbe8127e8',
]
const expectedSafeThreshold = 3

// ==================== CONTRACT ADDRESSES ====================
// Set to null to skip transferring ownership for that contract

// From setRolesConfig.js
const authorityAddress = '0x7F66AF3C7B7D80d6d4be937dE81cad42C0277eE3' // Base: RolesAuthority, from deployAll.js output
const boringVaultAddress = '0x1c6B29c8ac1E12A34D74DdaFCF016246d6aEdfff' // Base: from deployAll.js output
const accountantAddress = '0x23710C9fdF34b7E1eF28A92a19F9fdC0aC99518c' // Base: from deployAll.js output
const tellerAddress = '0xb02796D0b8e1f39265C48e31c94a48c428266Ddb' // Base: Teller, from deployAll.js output
const managerAddress = '0x4a90736b26353fea5C85f5cF941D85373C68AD0D' // Base: from deployAll.js output

// From setSolverRoles.js
const boringQueueAddress = '0xf68057c26eaF1F49800EaE86046B2b70Bd8Ded06' // Base: from 05_deployBoringQueue.js output
const boringSolverAddress = '0x73322B0c0CED7B6155068C22B53DC8954f739468' // Base: from 06_deployBoringSolver.js output

// ==================== ABI ====================
const ownerAbi = [
    'function transferOwnership(address newOwner) external',
    'function owner() view returns (address)',
]

const safeAbi = [
    'function getOwners() view returns (address[])',
    'function getThreshold() view returns (uint256)',
]

const contracts = [
    { name: 'RolesAuthority', address: authorityAddress },
    { name: 'BoringVault', address: boringVaultAddress },
    { name: 'Accountant', address: accountantAddress },
    { name: 'Teller', address: tellerAddress },
    { name: 'ManagerWithVerification', address: managerAddress },
    { name: 'BoringQueue', address: boringQueueAddress },
    { name: 'BoringSolver', address: boringSolverAddress },
]

async function main() {
    if (!newOwner || newOwner === ethers.constants.AddressZero) {
        throw new Error('newOwner address must be set')
    }

    const [deployer] = await ethers.getSigners()
    console.log('Deployer address:', deployer.address)
    console.log('New owner:', newOwner)

    // Ownership moves in one step, so check the Safe exists on this chain with the right signers first.
    if ((await ethers.provider.getCode(newOwner)) === '0x') {
        throw new Error(`newOwner ${newOwner} has no code on this chain: create the Safe here first`)
    }
    const safe = new ethers.Contract(newOwner, safeAbi, deployer)
    const owners = (await safe.getOwners()).map((o) => o.toLowerCase()).sort()
    const expected = expectedSafeOwners.map((o) => o.toLowerCase()).sort()
    const threshold = (await safe.getThreshold()).toNumber()
    if (owners.join() !== expected.join() || threshold !== expectedSafeThreshold) {
        const mismatch = `Safe ${newOwner} is ${threshold}-of-[${owners}] here, expected ${expectedSafeThreshold}-of-[${expected}]`
        // Escape hatch for handing over before the signers are fixed. Whoever holds the Safe's
        // current signers then controls every contract below, including fixing those signers.
        if (process.env.ALLOW_UNFIXED_SAFE_SIGNERS !== '1') {
            throw new Error(`${mismatch}: fix its signers first (or set ALLOW_UNFIXED_SAFE_SIGNERS=1 to hand over anyway)`)
        }
        console.log(`WARNING: ${mismatch}. Handing over anyway (ALLOW_UNFIXED_SAFE_SIGNERS=1).`)
    } else {
        console.log(`Safe signers verified: ${threshold}-of-${owners.length}`)
    }
    console.log()

    for (const { name, address } of contracts) {
        if (!address) {
            console.log(`Skipping ${name} (address is null)`)
            continue
        }

        console.log(`Transferring ownership of ${name} (${address})...`)
        const contract = new ethers.Contract(address, ownerAbi, deployer)

        const currentOwner = await contract.owner()
        if (currentOwner.toLowerCase() !== deployer.address.toLowerCase()) {
            console.log(`  SKIPPED — current owner is ${currentOwner}, not deployer`)
            continue
        }

        const tx = await contract.transferOwnership(newOwner)
        await tx.wait()
        console.log(`  tx: ${tx.hash}`)
    }

    console.log('\nOwnership transfers complete!')
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error)
        process.exit(1)
    })
