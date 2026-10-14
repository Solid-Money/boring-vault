const { ethers } = require('hardhat')

// ==================== DEPLOYED ADDRESSES ====================
const authorityAddress = '0x7F66AF3C7B7D80d6d4be937dE81cad42C0277eE3' // Base: RolesAuthority, from deployAll.js output
const boringQueueAddress = '0xf68057c26eaF1F49800EaE86046B2b70Bd8Ded06' // Base: from 05_deployBoringQueue.js output

// ==================== FUNCTION SELECTORS ====================
// setSolverRoles.js only makes requestOnChainWithdraw public. The live soUSD queue on Ethereum
// (0x5514…A964) also has these public, so users can cancel or re-price their own requests and
// request with a permit. Each one checks that msg.sender is the request's user.
// replaceOnChainWithdrawUsingRequestId is not public on soUSD either, so it stays off here.
const PUBLIC_QUEUE_FUNCTIONS = [
    ['requestOnChainWithdrawWithPermit', '0x581b4920'],
    ['cancelOnChainWithdraw', '0x4a2dc5e4'],
    ['cancelOnChainWithdrawUsingRequestId', '0x08bf866e'],
    ['replaceOnChainWithdraw', '0xa5672fd7'],
]

// ==================== ABI ====================
const authorityAbi = [
    'function setPublicCapability(address target, bytes4 functionSig, bool enabled) external',
    'function isCapabilityPublic(address target, bytes4 functionSig) external view returns (bool)',
]

async function main() {
    const [deployer] = await ethers.getSigners()
    console.log('Deployer address:', deployer.address)

    const authority = new ethers.Contract(authorityAddress, authorityAbi, deployer)

    for (const [name, selector] of PUBLIC_QUEUE_FUNCTIONS) {
        if (await authority.isCapabilityPublic(boringQueueAddress, selector)) {
            console.log(`BoringQueue.${name} is already public`)
            continue
        }
        console.log(`Setting public capability: BoringQueue.${name}`)
        const tx = await authority.setPublicCapability(boringQueueAddress, selector, true)
        await tx.wait()
        console.log('  tx:', tx.hash)
    }

    console.log('\nQueue public capabilities configured successfully!')
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error)
        process.exit(1)
    })
