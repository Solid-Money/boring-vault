const { ethers } = require('hardhat')

// ==================== DEPLOYED ADDRESSES ====================
const authorityAddress = '0x7F66AF3C7B7D80d6d4be937dE81cad42C0277eE3' // Base: RolesAuthority, from deployAll.js output
const boringQueueAddress = '0xf68057c26eaF1F49800EaE86046B2b70Bd8Ded06' // Base: from 05_deployBoringQueue.js output
const boringSolverAddress = '0x73322B0c0CED7B6155068C22B53DC8954f739468' // Base: from 06_deployBoringSolver.js output
const tellerAddress = '0xb02796D0b8e1f39265C48e31c94a48c428266Ddb' // Base: Teller, from deployAll.js output
// soETH's solver Safe. Not deployed on Base yet: recreate it at the same address (and fix its
// signers) before users can withdraw, since only it can process withdrawal requests.
const solverSafeAddress = '0xA7Fdc92eDa10eac8d6AfD3037d398929B57303D7'

// ==================== ROLE IDs ====================
const SOLVER_ROLE = 12
const BULK_WITHDRAW_ROLE = 36
const CAN_SOLVE_ROLE = 31
const ONLY_QUEUE_ROLE = 32

// ==================== FUNCTION SELECTORS ====================
const SOLVE_ON_CHAIN_WITHDRAWS_SELECTOR = '0x412638dc' // BoringQueue.solveOnChainWithdraws
const BULK_WITHDRAW_SELECTOR = '0x3e64ce99' // Teller.bulkWithdraw
const BORING_REDEEM_SOLVE_SELECTOR = '0x5ff8a71f' // BoringSolver.boringRedeemSolve
const BORING_SOLVE_SELECTOR = '0x67aa0416' // BoringSolver.boringSolve
const REQUEST_ON_CHAIN_WITHDRAW_SELECTOR = '0x6bb3b476' // BoringQueue.requestOnChainWithdraw


// ==================== ABI ====================
const authorityAbi = [
    'function setRoleCapability(uint8 role, address target, bytes4 functionSig, bool enabled) external',
    'function setUserRole(address user, uint8 role, bool enabled) external',
    'function setPublicCapability(address target, bytes4 functionSig, bool enabled) external',
]

async function main() {
    const [deployer] = await ethers.getSigners()
    console.log('Deployer address:', deployer.address)

    const authority = new ethers.Contract(authorityAddress, authorityAbi, deployer)

    // ==================== ROLE CAPABILITIES ====================

    // Role 12 — Solver can call solveOnChainWithdraws() on BoringQueue
    console.log('Setting Role 12: Solver -> BoringQueue.solveOnChainWithdraws')
    let tx = await authority.setRoleCapability(SOLVER_ROLE, boringQueueAddress, SOLVE_ON_CHAIN_WITHDRAWS_SELECTOR, true)
    await tx.wait()
    console.log('  tx:', tx.hash)

    // Role 36 — BulkWithdraw can call bulkWithdraw() on Teller
    console.log('Setting Role 36: BulkWithdraw -> Teller.bulkWithdraw')
    tx = await authority.setRoleCapability(BULK_WITHDRAW_ROLE, tellerAddress, BULK_WITHDRAW_SELECTOR, true)
    await tx.wait()
    console.log('  tx:', tx.hash)

    // Role 31 — CanSolve can call boringRedeemSolve() on BoringSolver
    console.log('Setting Role 31: CanSolve -> BoringSolver.boringRedeemSolve')
    tx = await authority.setRoleCapability(CAN_SOLVE_ROLE, boringSolverAddress, BORING_REDEEM_SOLVE_SELECTOR, true)
    await tx.wait()
    console.log('  tx:', tx.hash)

    // Role 32 — OnlyQueue can call boringSolve() on BoringSolver
    console.log('Setting Role 32: OnlyQueue -> BoringSolver.boringSolve')
    tx = await authority.setRoleCapability(ONLY_QUEUE_ROLE, boringSolverAddress, BORING_SOLVE_SELECTOR, true)
    await tx.wait()
    console.log('  tx:', tx.hash)

    // ==================== USER ROLE ASSIGNMENTS ====================

    // BoringSolver gets SOLVER_ROLE
    console.log('Assigning SOLVER_ROLE to BoringSolver')
    tx = await authority.setUserRole(boringSolverAddress, SOLVER_ROLE, true)
    await tx.wait()
    console.log('  tx:', tx.hash)

    // BoringSolver gets BULK_WITHDRAW_ROLE
    console.log('Assigning BULK_WITHDRAW_ROLE to BoringSolver')
    tx = await authority.setUserRole(boringSolverAddress, BULK_WITHDRAW_ROLE, true)
    await tx.wait()
    console.log('  tx:', tx.hash)

    // Solver Safe gets CAN_SOLVE_ROLE
    console.log('Assigning CAN_SOLVE_ROLE to Solver Safe')
    tx = await authority.setUserRole(solverSafeAddress, CAN_SOLVE_ROLE, true)
    await tx.wait()
    console.log('  tx:', tx.hash)

    // BoringQueue gets ONLY_QUEUE_ROLE
    console.log('Assigning ONLY_QUEUE_ROLE to BoringQueue')
    tx = await authority.setUserRole(boringQueueAddress, ONLY_QUEUE_ROLE, true)
    await tx.wait()
    console.log('  tx:', tx.hash)

    // Anyone can call requestOnChainWithdraw on BoringQueue
    console.log('Setting public capability: BoringQueue.requestOnChainWithdraw')
    tx = await authority.setPublicCapability(boringQueueAddress, REQUEST_ON_CHAIN_WITHDRAW_SELECTOR, true)
    await tx.wait()
    console.log('  tx:', tx.hash)

    console.log('\nAll solver roles and capabilities configured successfully!')
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error)
        process.exit(1)
    })
