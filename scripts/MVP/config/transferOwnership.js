const { ethers } = require('hardhat')

// ==================== NEW OWNER ====================
const newOwner = '0x6B26fAF3AD822695127B29ad242ac4B33D336F42' // Replace with new owner address (e.g. multisig)

// ==================== CONTRACT ADDRESSES ====================
// Set to null to skip transferring ownership for that contract

// From setRolesConfig.js
const authorityAddress = '0x1EC0EaeB8ff710F8387b3aD4dBdDdb12440ec7C0' // RolesAuthority
const boringVaultAddress = '0xEf1c1fFbEabDF358E61D3F5F14777e9c1bC8D1c7'
const accountantAddress = '0x4BD5873720072b4AC7956898dbCBc543b2fD3749'
const tellerAddress = '0xEaacf4534cCC05CAd929830fAF611d872b291d41' // LayerZeroTeller
const managerAddress = '0xF76278eFA47330c39Fc2Bc723d7Df15aDe2D1714'

// From setSolverRoles.js
const boringQueueAddress = '0xcfd7a4236ed557e9c2c03ce3256f091a0b60de28'
const boringSolverAddress = '0x0546bb4676936dc93f7eb5ca7ffd2e33a13de972' // Replace with deployed BoringSolver address

// ==================== ABI ====================
const ownerAbi = [
    'function transferOwnership(address newOwner) external',
    'function owner() view returns (address)',
]

const contracts = [
    { name: 'RolesAuthority', address: authorityAddress },
    { name: 'BoringVault', address: boringVaultAddress },
    { name: 'Accountant', address: accountantAddress },
    { name: 'LayerZeroTeller', address: tellerAddress },
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
