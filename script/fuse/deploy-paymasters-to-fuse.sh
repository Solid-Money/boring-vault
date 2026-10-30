#!/usr/bin/env bash
#
# Deploys the into-Fuse BridgePaymasters on Base, BNB Chain and Ethereum in one go, through
# BridgePaymasterToFuse.s.sol. Chains run in that order (cheapest first) and it stops at the
# first failure, so a problem on Base never reaches Ethereum.
#
#   script/fuse/deploy-paymasters-to-fuse.sh                     dry run on all three chains
#   script/fuse/deploy-paymasters-to-fuse.sh --broadcast         deploy, fund, then verify
#   script/fuse/deploy-paymasters-to-fuse.sh --broadcast base    only the chains named
#   script/fuse/deploy-paymasters-to-fuse.sh --verify            verify what is already deployed
#   script/fuse/deploy-paymasters-to-fuse.sh --transfer          hand each to its Safe
#
# Verification runs after every chain is deployed and a failure there only warns, so an explorer
# that refuses the key (Etherscan's free plan does not cover every chain) never stops a deploy.
#
# Env (default in brackets):
#   DEPLOYER_ACCOUNT    Foundry keystore account that deploys and owns them until --transfer [defaultKey]
#   ETHERSCAN_API_KEY   verifies on all three explorers; unset, contracts deploy unverified
#   VOUCHER_SIGNER      backend voucher key, the Fuse paymaster's [0x8bFcE4A1d7e02a0764CDc11BfD31715eeEc2Ab8A]
#   FEE_RECIPIENT       gets the fee taken in USDC / USDT [0x6c404c244e1aD2E1CE525492EbBd4a9C12E458aa]
#   BASE_RPC_URL, BNB_RPC_URL, ETHEREUM_RPC_URL                       [publicnode]
#   BASE_DAILY_FEE_BUDGET_WEI, BNB_..., ETHEREUM_...  native fee fronted per UTC day [see cfg]
#   BASE_FUNDING_WEI, BNB_..., ETHEREUM_...           native sent to the paymaster on deploy [see cfg]
#   NEW_OWNER_BASE, NEW_OWNER_BNB, NEW_OWNER_ETHEREUM the Safe each is handed to by --transfer
#
# Foundry asks for the keystore password once per chain.

set -euo pipefail

cd "$(dirname "$0")/../.."

# Other scripts and tests in this repo don't compile; limit the build to the Fuse paymaster's.
export FOUNDRY_SCRIPT=script/fuse FOUNDRY_TEST=test/fuse

SCRIPT=script/fuse/BridgePaymasterToFuse.s.sol
ACCOUNT=${DEPLOYER_ACCOUNT:-defaultKey}
export VOUCHER_SIGNER=${VOUCHER_SIGNER:-0x8bFcE4A1d7e02a0764CDc11BfD31715eeEc2Ab8A}
export FEE_RECIPIENT=${FEE_RECIPIENT:-0x6c404c244e1aD2E1CE525492EbBd4a9C12E458aa}

# Gas a deploy uses (implementation, proxy, initializeV2 and the pool calls), with headroom.
DEPLOY_GAS=6000000

cfg() {
    case "$1:$2" in
        base:rpc)         echo "${BASE_RPC_URL:-https://base-rpc.publicnode.com}" ;;
        base:budget)      echo "${BASE_DAILY_FEE_BUDGET_WEI:-50000000000000000}" ;;   # 0.05 ETH
        base:funding)     echo "${BASE_FUNDING_WEI:-100000000000000000}" ;;           # 0.1 ETH, ~185 sends
        base:owner)       echo "${NEW_OWNER_BASE:-}" ;;
        base:coin)        echo "ETH" ;;
        base:dir)         echo "Base" ;;
        base:chainid)     echo 8453 ;;
        bnb:rpc)          echo "${BNB_RPC_URL:-https://bsc-rpc.publicnode.com}" ;;
        bnb:budget)       echo "${BNB_DAILY_FEE_BUDGET_WEI:-200000000000000000}" ;;   # 0.2 BNB
        bnb:funding)      echo "${BNB_FUNDING_WEI:-200000000000000000}" ;;            # 0.2 BNB, ~110 sends
        bnb:owner)        echo "${NEW_OWNER_BNB:-}" ;;
        bnb:coin)         echo "BNB" ;;
        bnb:dir)          echo "BNB" ;;
        bnb:chainid)      echo 56 ;;
        ethereum:rpc)     echo "${ETHEREUM_RPC_URL:-https://ethereum-rpc.publicnode.com}" ;;
        ethereum:budget)  echo "${ETHEREUM_DAILY_FEE_BUDGET_WEI:-50000000000000000}" ;; # 0.05 ETH
        ethereum:funding) echo "${ETHEREUM_FUNDING_WEI:-50000000000000000}" ;;         # 0.05 ETH, ~90 sends
        ethereum:owner)   echo "${NEW_OWNER_ETHEREUM:-}" ;;
        ethereum:coin)    echo "ETH" ;;
        ethereum:dir)     echo "Mainnet" ;;
        ethereum:chainid) echo 1 ;;
        *) echo "unknown setting $1:$2" >&2; exit 1 ;;
    esac
}

usage() {
    sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

MODE=dry
CHAINS=()
for arg in "$@"; do
    case "$arg" in
        --broadcast) MODE=broadcast ;;
        --verify)    MODE=verify ;;
        --transfer)  MODE=transfer ;;
        base|bnb|ethereum) CHAINS+=("$arg") ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $arg" >&2; usage ;;
    esac
done
[ ${#CHAINS[@]} -eq 0 ] && CHAINS=(base bnb ethereum)

ether() { cast from-wei "$1"; }

address_file() { echo "deployments/addresses/$(cfg "$1" dir)/BridgePaymaster.json"; }

# Verifies a chain's recorded implementation and proxy. Warns rather than fails, so one explorer
# refusing never stops the others.
verify_chain() {
    local chain=$1 file impl proxy
    file=$(address_file "$chain")
    if [ ! -f "$file" ]; then
        echo "$chain: nothing recorded in $file - skipping"
        return 0
    fi
    impl=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["contractAddresses"]["BridgePaymasterImplementation"])' "$file")
    proxy=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["contractAddresses"]["BridgePaymaster"])' "$file")
    echo "===== $chain: verify implementation $impl and proxy $proxy"
    forge verify-contract "$impl" src/fuse/BridgePaymaster.sol:BridgePaymaster \
        --chain "$(cfg "$chain" chainid)" --rpc-url "$(cfg "$chain" rpc)" \
        --etherscan-api-key "$ETHERSCAN_API_KEY" --watch ||
        echo "  -> could not verify the implementation on $chain; re-run with --verify $chain later" >&2
    # The proxy's constructor arguments, from Foundry's record of the deploy. Guessing them instead
    # needs an explorer API call Etherscan's free plan refuses on some chains.
    local args
    args=$(python3 - "broadcast/BridgePaymasterToFuse.s.sol/$(cfg "$chain" chainid)/run-latest.json" "$proxy" <<'PY'
import json, sys
for t in json.load(open(sys.argv[1]))["transactions"]:
    if t.get("transactionType") == "CREATE" and t["contractAddress"].lower() == sys.argv[2].lower():
        print(" ".join(t["arguments"]))
PY
    )
    [ -n "$args" ] || { echo "  -> no deploy record for the proxy on $chain; cannot verify it" >&2; return 0; }
    # shellcheck disable=SC2086 # two words: the implementation and the init calldata
    forge verify-contract "$proxy" lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
        --chain "$(cfg "$chain" chainid)" --rpc-url "$(cfg "$chain" rpc)" \
        --constructor-args "$(cast abi-encode "constructor(address,bytes)" $args)" \
        --etherscan-api-key "$ETHERSCAN_API_KEY" --watch ||
        echo "  -> could not verify the proxy on $chain; re-run with --verify $chain later" >&2
}

# ---------------------------------------------------------------------------------------------
# --verify: verify what is already deployed. Needs no password.
# ---------------------------------------------------------------------------------------------
if [ "$MODE" = verify ]; then
    [ -n "${ETHERSCAN_API_KEY:-}" ] || { echo "Set ETHERSCAN_API_KEY to verify." >&2; exit 1; }
    for chain in "${CHAINS[@]}"; do
        verify_chain "$chain"
    done
    exit 0
fi

# ---------------------------------------------------------------------------------------------
# Dry run: simulate every deploy and its checks. Nothing is sent and no password is needed.
# ---------------------------------------------------------------------------------------------
if [ "$MODE" = dry ]; then
    for chain in "${CHAINS[@]}"; do
        echo "===== $chain (dry run)"
        DAILY_FEE_BUDGET_WEI=$(cfg "$chain" budget) FUNDING_WEI=0 \
            forge script "$SCRIPT:DeployBridgePaymasterToFuse" --rpc-url "$(cfg "$chain" rpc)" 2>&1 |
            sed -n '/== Logs ==/,/Next:/p'
    done
    echo
    echo "Dry run passed. Deploy with: $0 --broadcast ${CHAINS[*]}"
    exit 0
fi

DEPLOYER=$(cast wallet address --account "$ACCOUNT")
echo "Deployer: $DEPLOYER ($ACCOUNT)"

# ---------------------------------------------------------------------------------------------
# --transfer: hand each paymaster to its Safe. The Solidity step refuses anything that is not a
# Safe with a threshold of at least 2.
# ---------------------------------------------------------------------------------------------
if [ "$MODE" = transfer ]; then
    for chain in "${CHAINS[@]}"; do
        owner=$(cfg "$chain" owner)
        [ -n "$owner" ] || { echo "Set NEW_OWNER_$(echo "$chain" | tr a-z A-Z) to the Safe on $chain" >&2; exit 1; }
    done
    for chain in "${CHAINS[@]}"; do
        echo "===== $chain: transfer to $(cfg "$chain" owner)"
        NEW_OWNER=$(cfg "$chain" owner) \
            forge script "$SCRIPT:TransferBridgePaymasterToFuseOwnership" \
            --rpc-url "$(cfg "$chain" rpc)" --account "$ACCOUNT" --sender "$DEPLOYER" --broadcast
    done
    exit 0
fi

# ---------------------------------------------------------------------------------------------
# --broadcast: check every chain first, so a short balance on Ethereum is caught before Base is
# deployed, then confirm, then deploy in order.
# ---------------------------------------------------------------------------------------------
short=0
echo
printf '%-10s %-22s %-22s %-22s %s\n' chain balance "funding" "daily limit" "needs (funding + gas)"
for chain in "${CHAINS[@]}"; do
    rpc=$(cfg "$chain" rpc)
    file=$(address_file "$chain")
    if [ -f "$file" ]; then
        echo "$chain already has a paymaster recorded in $file - remove the chain from the list or the file" >&2
        exit 1
    fi
    balance=$(cast balance "$DEPLOYER" --rpc-url "$rpc")
    gas_price=$(cast gas-price --rpc-url "$rpc")
    funding=$(cfg "$chain" funding)
    need=$(echo "$funding + $DEPLOY_GAS * $gas_price * 2" | bc)
    coin=$(cfg "$chain" coin)
    printf '%-10s %-22s %-22s %-22s %s\n' "$chain" "$(ether "$balance") $coin" "$(ether "$funding") $coin" \
        "$(ether "$(cfg "$chain" budget)") $coin" "$(ether "$need") $coin"
    if [ "$(echo "$balance < $need" | bc)" = 1 ]; then
        echo "  -> not enough $coin on $chain" >&2
        short=1
    fi
done
[ "$short" = 0 ] || { echo "Top up the deployer and run again; nothing was deployed." >&2; exit 1; }

[ -n "${ETHERSCAN_API_KEY:-}" ] ||
    echo "ETHERSCAN_API_KEY is not set: the contracts will deploy unverified (verify later with --verify)."

echo
echo "Voucher signer: $VOUCHER_SIGNER"
echo "Fee recipient:  $FEE_RECIPIENT"
read -r -p "Deploy on ${CHAINS[*]} from $DEPLOYER? Type 'deploy' to continue: " answer
[ "$answer" = deploy ] || { echo "Stopped; nothing was deployed."; exit 1; }

for chain in "${CHAINS[@]}"; do
    echo
    echo "===== $chain"
    # The Solidity step records the addresses there, and Foundry drops the whole broadcast if
    # that write fails - so the folder has to exist first (deployments/addresses/BNB is new).
    mkdir -p "$(dirname "$(address_file "$chain")")"
    DAILY_FEE_BUDGET_WEI=$(cfg "$chain" budget) FUNDING_WEI=$(cfg "$chain" funding) \
        forge script "$SCRIPT:DeployBridgePaymasterToFuse" \
        --rpc-url "$(cfg "$chain" rpc)" --account "$ACCOUNT" --sender "$DEPLOYER" --broadcast
done

if [ -n "${ETHERSCAN_API_KEY:-}" ]; then
    for chain in "${CHAINS[@]}"; do
        echo
        verify_chain "$chain"
    done
fi

echo
echo "Deployed on ${CHAINS[*]}. Addresses are in deployments/addresses/*/BridgePaymaster.json - commit them."
echo "Once tested, hand them over: NEW_OWNER_<CHAIN>=<safe> $0 --transfer ${CHAINS[*]}"
