---
description: Flatten a Solidity contract for verification or deployment
allowed-tools: Bash, Read, Glob, Grep, Write
---

Flatten a Solidity contract into a single file for block explorer verification or direct deployment.

Steps:
1. Run `forge flatten <contract_path>` to produce the flattened output
2. Save the flattened file alongside the original with a `_flattened.sol` suffix
3. Verify it compiles: `forge build`

If the user doesn't specify a contract, ask which one to flatten.

Contract to flatten: $ARGUMENTS
