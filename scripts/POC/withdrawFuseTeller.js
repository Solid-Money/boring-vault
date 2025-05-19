require('dotenv').config()
const { ethers } = require('ethers')

// ABIs
const VAULT_ABI = [
  'function balanceOf(address owner) external view returns (uint256)',
  'function approve(address spender, uint256 amount) external returns (bool)',
]

const FUSE_TELLER_ABI = [
  'function withdraw(uint256 shares) external',
  'event Withdraw(address indexed caller, uint256 shares)',
]

/**
 * Withdraw shares from the FuseTeller contract
 * @param {string} amount - Amount to withdraw in ETH units
 * @returns {Promise<object>} - Transaction receipt
 */
async function withdrawFromFuseTeller(amount = '0.0009') {
  console.log('Starting withdraw process from FuseTeller')

  // Environment variables
  const rpcUrl = process.env.FUSE_RPC_URL
  const privateKey = process.env.PRIVATE_KEY
  const tellerAddress = process.env.FUSE_TELLER
  const vaultAddress = process.env.VAULT_FUSE

  if (!tellerAddress) {
    throw new Error('FUSE_TELLER address is not defined in .env file')
  }

  // Setup provider and signer
  const provider = new ethers.providers.JsonRpcProvider(rpcUrl)
  const wallet = new ethers.Wallet(privateKey, provider)
  const address = await wallet.getAddress()

  console.log(`Using wallet address: ${address}`)
  console.log(`FuseTeller address: ${tellerAddress}`)

  // Parse the amount to wei
  const sharesAmount = ethers.utils.parseEther(amount)
  console.log(`Will withdraw ${amount} shares (${sharesAmount.toString()} wei)`)

  try {
    // Check vault balance to ensure we have enough shares
    const vault = new ethers.Contract(vaultAddress, VAULT_ABI, wallet)
    const balance = await vault.balanceOf(address)
    console.log(`Vault token balance: ${ethers.utils.formatEther(balance)} shares`)

    if (balance.lt(sharesAmount)) {
      throw new Error(
        `Insufficient balance: ${ethers.utils.formatEther(balance)} shares`
      )
    }

    // Approve teller to spend vault tokens if needed
    console.log('Approving FuseTeller to spend vault tokens...')
    const approveTx = await vault.approve(tellerAddress, sharesAmount)
    console.log(`Approval transaction: ${approveTx.hash}`)
    await approveTx.wait()
    console.log('Approval confirmed')

    // Call withdraw on the FuseTeller contract
    console.log('Withdrawing from FuseTeller...')
    const teller = new ethers.Contract(
      tellerAddress,
      FUSE_TELLER_ABI,
      wallet
    )
    
    const withdrawTx = await teller.withdraw(sharesAmount)
    console.log(`Withdraw transaction: ${withdrawTx.hash}`)

    // Wait for confirmation
    const receipt = await withdrawTx.wait()
    console.log(`Withdraw confirmed in block ${receipt.blockNumber}`)

    // Check for Withdraw event
    const withdrawEvent = receipt.events?.find(e => e.event === 'Withdraw')
    if (withdrawEvent) {
      console.log('Withdraw event emitted:')
      console.log(` - Caller: ${withdrawEvent.args.caller}`)
      console.log(` - Shares: ${ethers.utils.formatEther(withdrawEvent.args.shares)}`)
    }

    return receipt
  } catch (error) {
    console.error('Withdraw failed:', error.message)
    throw error
  }
}

// Execute if run directly
if (require.main === module) {
  // Use the specified amount or default to 0.0009
  const amount = '0.0009'

  withdrawFromFuseTeller(amount)
    .then(() => {
      console.log('Withdraw completed successfully')
      process.exit(0)
    })
    .catch((error) => {
      console.error('Error during withdraw:', error)
      process.exit(1)
    })
}

module.exports = { withdrawFromFuseTeller }
