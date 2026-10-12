---
description: Deploy Boring Vault contracts using the MVP Hardhat scripts
allowed-tools: Bash, Read, Glob, Grep, Edit, Write
---

Deploy contracts for the Boring Vault system. The deployment scripts are in `scripts/MVP/` and should be run in order:

1. `01_deployBoringVault.js` - Core vault contract
2. `02_deployAccountantWithRateProvider.js` - Rate oracle & fee handler
3. `03_deployLayerZeroTeller.js` - Cross-chain LayerZero teller
4. `04_deployManagerWithverification.js` - Merkle-verified strategy manager
5. `05_deployBoringQueue.js` - On-chain withdrawal queue
6. `06_deployBoringSolver.js` - Queue solver/executor

Before deploying:
- Verify `.env` has the correct `PRIVATE_KEY` and RPC URLs set
- Check that contract addresses in the script configs are correct for the target network
- Confirm the target network with the user (default: Fuse, chainId 122)

Run with: `npx hardhat run scripts/MVP/<script> --network <network>`

Available networks: `mainnet`, `fuse`, `base`

After each deployment, report the deployed contract address and verify the authority/role setup was successful.

User argument (if any): $ARGUMENTS
