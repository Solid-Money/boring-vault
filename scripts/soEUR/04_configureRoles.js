const { ethers } = require('hardhat')
const {
  MAINNET_CHAIN_ID,
  PROFILE,
  profile,
  required,
  ROLES,
  ROLES_AUTHORITY_ABI,
  OWNED_ABI,
  requireNetwork,
  requireDeployed,
  sendTx,
  sighash,
  writeSafeBatch,
} = require('./config')

// Roles on the Ethereum soEUR authority, then ownership of vault, manager and authority to the
// profile's owner:
//   MANAGER (1)    vault.manage(address,bytes,uint256) and manage(address[],bytes[],uint256[]); held by the manager
//   STRATEGIST (7) manager.manageVaultWithMerkleVerification; held by the strategist
// Only missing roles are set. They are sent while the deployer owns the authority; once the owner holds
// it, they are written as a Safe batch for the owner instead.
async function main() {
  const chainId = await requireNetwork(MAINNET_CHAIN_ID)
  const owner = required(profile.mainnet.owner, 'mainnet.owner')
  const strategist = required(profile.mainnet.strategist, 'mainnet.strategist')
  const authorityAddress = requireDeployed(chainId, 'RolesAuthority')
  const vaultAddress = requireDeployed(chainId, 'BoringVault')
  const managerAddress = requireDeployed(chainId, 'ManagerWithMerkleVerification')
  const [deployer] = await ethers.getSigners()
  console.log(`soEUR (${PROFILE}) on Ethereum; deployer ${deployer.address}, owner ${owner}`)

  const authority = new ethers.Contract(authorityAddress, ROLES_AUTHORITY_ABI, deployer)
  const txs = []
  const roleCapability = async (role, target, contract, signature, label) => {
    const sig = sighash(contract, signature)
    if (await authority.doesRoleHaveCapability(role, target, sig)) {
      console.log(`  set  role ${role} -> ${label}.${signature}`)
      return
    }
    txs.push({
      to: authorityAddress,
      data: authority.interface.encodeFunctionData('setRoleCapability', [role, target, sig, true]),
      description: `role ${role} -> ${label}.${signature}`,
    })
  }
  const userRole = async (user, role, label) => {
    if (await authority.doesUserHaveRole(user, role)) {
      console.log(`  set  ${label} ${user} has role ${role}`)
      return
    }
    txs.push({
      to: authorityAddress,
      data: authority.interface.encodeFunctionData('setUserRole', [user, role, true]),
      description: `${label} ${user} gets role ${role}`,
    })
  }

  await roleCapability(ROLES.MANAGER, vaultAddress, 'BoringVault', 'manage(address,bytes,uint256)', 'vault')
  await roleCapability(ROLES.MANAGER, vaultAddress, 'BoringVault', 'manage(address[],bytes[],uint256[])', 'vault')
  await roleCapability(
    ROLES.STRATEGIST,
    managerAddress,
    'Manager',
    'manageVaultWithMerkleVerification(bytes32[][],address[],address[],bytes[],uint256[])',
    'manager',
  )
  await userRole(managerAddress, ROLES.MANAGER, 'Manager')
  await userRole(strategist, ROLES.STRATEGIST, 'Strategist')

  const authorityOwner = await new ethers.Contract(authorityAddress, OWNED_ABI, deployer).owner()
  if (txs.length === 0) {
    console.log('All roles already set')
  } else if (authorityOwner.toLowerCase() === deployer.address.toLowerCase()) {
    for (const tx of txs) {
      console.log(tx.description)
      await sendTx(deployer.sendTransaction({ to: tx.to, data: tx.data }))
    }
  } else if ((await ethers.provider.getCode(authorityOwner)) !== '0x') {
    console.log(`Authority is owned by ${authorityOwner}, not the deployer; writing a batch instead`)
    await writeSafeBatch({
      fileName: `mainnet-soeur-${PROFILE}-roles.json`,
      name: `soEUR ${PROFILE} Ethereum: manager and strategist roles`,
      safe: authorityOwner,
      txs,
    })
  } else {
    throw new Error(`Authority owner ${authorityOwner} is an EOA other than the deployer; cannot send or batch for it`)
  }

  // Authority last: the deployer needs it until every role above has landed.
  for (const [name, address] of [
    ['BoringVault', vaultAddress],
    ['ManagerWithMerkleVerification', managerAddress],
    ['RolesAuthority', authorityAddress],
  ]) {
    const contract = new ethers.Contract(address, OWNED_ABI, deployer)
    const currentOwner = await contract.owner()
    if (currentOwner.toLowerCase() === owner.toLowerCase()) {
      console.log(`${name} already owned by ${owner}`)
    } else if (currentOwner.toLowerCase() === deployer.address.toLowerCase()) {
      console.log(`Transferring ${name} (${address}) to ${owner}...`)
      await sendTx(contract.transferOwnership(owner))
    } else {
      throw new Error(`${name} is owned by ${currentOwner}, neither the deployer nor ${owner}`)
    }
  }

  console.log('\nNext: once the backend has the new merkle roots, the owner calls setManageRoot(strategist, root) on')
  console.log(`  Base soEUR manager:     ${profile.base.manager || '(base.manager not set in config.js)'}`)
  console.log(`  Ethereum soEUR manager: ${managerAddress}`)
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
