require('dotenv').config()
const { ethers } = require('ethers')

// ABIs
const WETH_ABI = [
  'function deposit() external payable',
  'function approve(address spender, uint256 amount) external returns (bool)',
  'function balanceOf(address owner) external view returns (uint256)',
]

const ETHEREUM_TELLER_ABI = [
  'function deposit(uint256 amount) external',
  'event Deposit(address indexed caller, uint256 amount)',
]

/**
 * Automatically convert ETH to WETH, approve and deposit to the EthereumTeller contract
 * @param {string} amount - Amount of ETH to deposit (in ETH units)
 * @returns {Promise<object>} - Transaction receipt
 */
async function depositEthToTeller(amount = '0.01') {
  console.log('Starting automatic WETH deposit process')

  // Environment variables
  const rpcUrl = process.env.MAINNET_RPC_URL
  const privateKey = process.env.PRIVATE_KEY
  const tellerAddress = process.env.ETHEREUM_TELLER
  const wethAddress = process.env.WETH

  // Setup provider and signer
  const provider = new ethers.providers.JsonRpcProvider(rpcUrl)
  const wallet = new ethers.Wallet(privateKey, provider)
  const address = await wallet.getAddress()

  console.log(`Using wallet address: ${address}`)
  console.log(`Teller address: ${tellerAddress}`)

  // Parse the amount to wei
  const amountWei = ethers.utils.parseEther(amount)
  console.log(`Will deposit ${amount} ETH (${amountWei.toString()} wei)`)

  try {
    // Create WETH contract instance
    const weth = new ethers.Contract(wethAddress, WETH_ABI, wallet)

    // Verify WETH balance
    const balance = await weth.balanceOf(address)
    console.log(`WETH balance: ${ethers.utils.formatEther(balance)} WETH`)

    if (balance.lt(amountWei)) {
      throw new Error(
        `Insufficient WETH balance: ${ethers.utils.formatEther(balance)}`
      )
    }

    // Approve teller to spend WETH
    console.log('Approving EthereumTeller to spend WETH...')
    const approveTx = await weth.approve(tellerAddress, amountWei)
    console.log(`Approval transaction: ${approveTx.hash}`)
    await approveTx.wait()

    // Deposit WETH to the teller
    console.log('Depositing WETH to EthereumTeller...')
    const teller = new ethers.Contract(
      tellerAddress,
      ETHEREUM_TELLER_ABI,
      wallet
    )
    const depositTellerTx = await teller.deposit(amountWei)
    console.log(`Deposit transaction: ${depositTellerTx.hash}`)

    // Wait for confirmation
    const receipt = await depositTellerTx.wait()
    console.log(`Deposit confirmed in block ${receipt.blockNumber}`)

    return receipt
  } catch (error) {
    console.error('Deposit failed:', error.message)
    throw error
  }
}

// Execute if run directly
if (require.main === module) {
  // Get amount from command line if provided, otherwise use default
  const amount = '0.0009'

  depositEthToTeller(amount)
    .then(() => {
      console.log('Deposit completed successfully')
      process.exit(0)
    })
    .catch((error) => {
      console.error('Error during deposit:', error)
      process.exit(1)
    })
}

module.exports = { depositEthToTeller }
