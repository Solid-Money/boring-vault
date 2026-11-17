#!/usr/bin/env bash
# Fetches live LI.FI quotes for the fork test of BridgePaymaster.lifiCall
# (test/fuse/BridgePaymasterLifiCallFork.t.sol): Base → Fuse over Stargate, with the
# Base paymaster as the sender LI.FI quotes for and a test Safe as the receiver.
#
# Quotes go stale within minutes (DEX calldata deadlines, the LayerZero fee), so fetch
# them right before the test, which forks Base at its latest block:
#
#   script/fuse/lifi-sponsored-fixtures.sh && \
#     LIFI_FIXTURES=cache/lifi-fixtures forge test --match-path test/fuse/BridgePaymasterLifiCallFork.t.sol
set -euo pipefail

OUT=${1:-cache/lifi-fixtures}
PAYMASTER=0xC4F4bb4CD9C2098Dd1Eb11e0055FD0E212c967fc
# Must match RECEIVER in the fork test.
RECEIVER=0x5Afe00000000000000000000000000000000bEeF
FUSE_USDC=0xc6Bc407706B7140EE8Eef2f86F9504651b63e7f9
WFUSE=0x0BE9e53fd7EDaC9F859882AfdDa116645287C629
mkdir -p "$OUT"

fetch() { # name fromToken toToken fromAmount
  local query="fromChain=8453&toChain=122&fromToken=$2&toToken=$3&fromAmount=$4"
  query+="&fromAddress=$PAYMASTER&toAddress=$RECEIVER&slippage=0.01&allowBridges=stargateV2"
  curl -sf --max-time 60 "https://li.quest/v1/quote?$query" | python3 -I -c '
import json, sys
q = json.load(sys.stdin)
tx = q["transactionRequest"]
json.dump({
    "data": tx["data"],
    "value": str(int(tx["value"], 16)),
    "fromToken": q["action"]["fromToken"]["address"],
    "fromAmount": q["action"]["fromAmount"],
}, sys.stdout)' > "$OUT/$1.json"
  echo "fetched $OUT/$1.json"
}

fetch uni-to-wfuse 0xc3De830EA07524a0761646a6a4e4be0e114a3C83 $WFUSE 10000000000000000000
fetch usdc-to-usdc 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 $FUSE_USDC 10000000
fetch eth-to-usdc 0x0000000000000000000000000000000000000000 $FUSE_USDC 5000000000000000
