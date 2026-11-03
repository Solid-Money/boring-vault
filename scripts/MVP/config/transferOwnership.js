const { ethers } = require('hardhat')
const deployment = require('../deployment').load()

// ==================== NEW OWNER ====================
// From the deployment record. When the record describes the owner as a Safe (ownerSafe), the guard
// in main() refuses to hand anything over unless the Safe on this chain has exactly those signers;
// otherwise the owner must be a plain EOA (no code).
const newOwner = deployment.config.owner
const ownerSafe = deployment.config.ownerSafe

// ==================== CONTRACT ADDRESSES ====================
// Set to null to skip transferring ownership for that contract

// From setRolesConfig.js
const authorityAddress = deployment.address('RolesAuthority')
const boringVaultAddress = deployment.address('BoringVault')
const accountantAddress = deployment.address('Accountant')
const tellerAddress = deployment.address('Teller')
const managerAddress = deployment.address('Manager')

// From setSolverRoles.js
const boringQueueAddress = deployment.address('BoringQueue')
const boringSolverAddress = deployment.address('BoringSolver')

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
    await deployment.check(ethers)
    if (!newOwner || newOwner === ethers.constants.AddressZero) {
        throw new Error('newOwner address must be set')
    }

    const [deployer] = await ethers.getSigners()
    console.log('Deployer address:', deployer.address)
    console.log('New owner:', newOwner)

    // Ownership moves in one step, so check the new owner is what the record says it is first.
    const code = await ethers.provider.getCode(newOwner)
    if (!ownerSafe) {
        if (code !== '0x') {
            throw new Error(`newOwner ${newOwner} has code on this chain: describe it as ownerSafe in ${deployment.file}`)
        }
        console.log('New owner is an EOA (no code), as the record says')
    } else {
        if (code === '0x') {
            throw new Error(`newOwner ${newOwner} has no code on this chain: create the Safe here first`)
        }
        const safe = new ethers.Contract(newOwner, safeAbi, deployer)
        const owners = (await safe.getOwners()).map((o) => o.toLowerCase()).sort()
        const expected = ownerSafe.owners.map((o) => o.toLowerCase()).sort()
        const threshold = (await safe.getThreshold()).toNumber()
        if (owners.join() !== expected.join() || threshold !== ownerSafe.threshold) {
            const mismatch = `Safe ${newOwner} is ${threshold}-of-[${owners}] here, expected ${ownerSafe.threshold}-of-[${expected}]`
            // Escape hatch for handing over before the signers are fixed. Whoever holds the Safe's
            // current signers then controls every contract below, including fixing those signers.
            if (process.env.ALLOW_UNFIXED_SAFE_SIGNERS !== '1') {
                throw new Error(`${mismatch}: fix its signers first (or set ALLOW_UNFIXED_SAFE_SIGNERS=1 to hand over anyway)`)
            }
            console.log(`WARNING: ${mismatch}. Handing over anyway (ALLOW_UNFIXED_SAFE_SIGNERS=1).`)
        } else {
            console.log(`Safe signers verified: ${threshold}-of-${owners.length}`)
        }
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
