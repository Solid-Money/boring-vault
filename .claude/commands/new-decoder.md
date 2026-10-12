---
description: Create a new DecoderAndSanitizer for a DeFi protocol integration
allowed-tools: Bash, Read, Glob, Grep, Edit, Write
---

Create a new DecoderAndSanitizer contract for integrating a DeFi protocol with the Boring Vault system.

Steps:
1. Read existing decoders in `src/base/DecodersAndSanitizers/Solid/` for reference patterns
2. Read the base decoder at `src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol`
3. Create the new decoder following the established pattern:
   - Inherit from `BaseDecoderAndSanitizer`
   - Define functions that match the target protocol's function signatures
   - Extract and validate addresses from calldata using `abi.decode`
   - Return `(bytes memory addressesFound)` with packed addresses for sanitization
4. Place the new file in `src/base/DecodersAndSanitizers/Solid/`
5. Compile with `forge build` to verify

Protocol to integrate: $ARGUMENTS
