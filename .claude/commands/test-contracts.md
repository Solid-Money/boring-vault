---
description: Build and test Solidity contracts using Foundry
allowed-tools: Bash, Read, Glob, Grep
---

Build and run tests for the Boring Vault contracts.

Commands:
- Build: `forge build`
- Test all: `forge test`
- Test verbose: `forge test -vvv`
- Test specific file: `forge test --match-path test/<file>.t.sol`
- Test specific function: `forge test --match-test <testName>`
- Gas report: `forge test --gas-report`

If tests fail, analyze the error output and report:
1. Which test(s) failed
2. The revert reason or assertion failure
3. Suggested fix

If the user specifies a target, run only the relevant tests. Otherwise, run the full suite.

Target (optional): $ARGUMENTS
