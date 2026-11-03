const { ethers } = require('hardhat')
const deployment = require('../deployment').load()

// ==================== DEPLOYED ADDRESSES ====================
const authorityAddress = deployment.address('RolesAuthority')

// Makes CAN_SOLVE_ROLE (who may call BoringSolver.boringRedeemSolve) match the record: granted to
// the solver operator, revoked from any former operator listed there. setSolverRoles.js already
// grants it on a fresh deployment; this moves it after the operator changes.
const solverOperator = deployment.config.solverOperator
const formerSolverOperators = deployment.config.formerSolverOperators || []

// ==================== ROLE IDs ====================
const CAN_SOLVE_ROLE = 31

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

    const changes = [
        ['Granting CAN_SOLVE_ROLE to the solver operator', solverOperator, true],
        ...formerSolverOperators.map((user) => ['Revoking CAN_SOLVE_ROLE from a former solver operator', user, false]),
    ]
    for (const [label, user, enabled] of changes) {
        if ((await authority.doesUserHaveRole(user, CAN_SOLVE_ROLE)) === enabled) {
            console.log(`${label}: already done`)
            continue
        }
        console.log(`${label} (${user})`)
        // Fixed gas limit: a lagging RPC node can return a bad estimate. wait() throws if the tx fails.
        const tx = await authority.setUserRole(user, CAN_SOLVE_ROLE, enabled, { gasLimit: 100000 })
        await tx.wait()
        console.log('  tx:', tx.hash)
    }

    console.log('\nSolver operator configured successfully!')
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error)
        process.exit(1)
    })
