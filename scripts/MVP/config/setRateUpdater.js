const { ethers } = require('hardhat')
const deployment = require('../deployment').load()

// ==================== DEPLOYED ADDRESSES ====================
const authorityAddress = deployment.address('RolesAuthority')

// Makes UPDATE_EXCHANGE_RATE_ROLE match the record: granted to the rate updater and, when the
// strategist is a different address, not held by the strategist (as on the other prod vaults).
// setRolesConfig.js already does this for a fresh deployment; this fixes one deployed before that.
const rateUpdater = deployment.config.rateUpdater
const strategistEOA = deployment.config.strategist

// ==================== ROLE IDs ====================
const UPDATE_EXCHANGE_RATE_ROLE = 11

// ==================== ABI ====================
const authorityAbi = [
    'function setUserRole(address user, uint8 role, bool enabled) external',
    'function doesUserHaveRole(address user, uint8 role) external view returns (bool)',
]

async function main() {
    await deployment.check(ethers)
    const [deployer] = await ethers.getSigners()
    console.log('Deployer address:', deployer.address)

    const authority = new ethers.Contract(authorityAddress, authorityAbi, deployer)

    const changes = [['Granting UPDATE_EXCHANGE_RATE_ROLE to the rate updater', rateUpdater, true]]
    if (strategistEOA.toLowerCase() !== rateUpdater.toLowerCase()) {
        changes.push(['Revoking UPDATE_EXCHANGE_RATE_ROLE from the strategist', strategistEOA, false])
    }
    for (const [label, user, enabled] of changes) {
        if ((await authority.doesUserHaveRole(user, UPDATE_EXCHANGE_RATE_ROLE)) === enabled) {
            console.log(`${label}: already done`)
            continue
        }
        console.log(`${label} (${user})`)
        // Fixed gas limit: a lagging RPC node can return a bad estimate. wait() throws if the tx fails.
        const tx = await authority.setUserRole(user, UPDATE_EXCHANGE_RATE_ROLE, enabled, { gasLimit: 100000 })
        await tx.wait()
        console.log('  tx:', tx.hash)
    }

    console.log('\nRate updater configured successfully!')
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error)
        process.exit(1)
    })
