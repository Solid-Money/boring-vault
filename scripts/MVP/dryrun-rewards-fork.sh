#!/usr/bin/env bash
# Dry run of the reward conversion upgrade for one LIVE stock vault (VAULT_SYMBOL, prod record)
# against a LOCAL anvil fork of Base: deploy the swap decoder, build the new tree, set its root as
# the impersonated owner Safe, then run the new actions as the impersonated strategist: swap USDC
# into the stock on KyberSwap, request and cancel an sUP redeem, and deposit the swapped stock into
# the SuperVault through a leaf the old root already had. Works on a scratch copy of the record and
# signs with anvil's public test key. Nothing is sent to real Base.
#
# KyberSwap builds its route from real Base, so run it against a fresh fork.
# 1. In one terminal:  ~/.foundry/versions/v1.8.7/anvil --fork-url https://mainnet.base.org --port 8545 --network base
# 2. In another:       VAULT_SYMBOL=soNVDA bash scripts/MVP/dryrun-rewards-fork.sh
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
FORK=http://127.0.0.1:8545
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SYMBOL=${VAULT_SYMBOL:?Set VAULT_SYMBOL, e.g. soNVDA}
cd "$REPO"
[ "$(cast chain-id -r $FORK 2>/dev/null)" = "8453" ] || { echo "fork not up or not Base"; exit 1; }

mkdir -p .dryrun
export DEPLOYMENT_FILE=$REPO/.dryrun/$SYMBOL-rewards.json
cp "deployments/addresses/Base/$SYMBOL.json" "$DEPLOYMENT_FILE"
export PRIVATE_KEY=$K0 BASE_RPC_URL=$FORK MAINNET_RPC_URL=$FORK FUSE_RPC_URL=$FORK
cfg() { python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]].get(sys.argv[3]) or "")' "$DEPLOYMENT_FILE" "$@"; }
c() { cast call -r $FORK "$@" 2>/dev/null; }
num() { c "$@" | awk '{print $1}'; }
imp() { for a in "$@"; do cast rpc -r $FORK anvil_impersonateAccount $a >/dev/null; cast rpc -r $FORK anvil_setBalance $a 0x56BC75E2D63100000 >/dev/null; done; }
ok() { cast send -r $FORK --unlocked --from "$@" 2>&1 | grep -qE '^status +1' && echo succeeded || echo reverted; }
hh() { npx hardhat run "$@" --network base --no-compile 2>&1 | grep -v deny_warnings; }
manage() {
  STRATEGIST_UNLOCKED=1 ACTION=$1 AMOUNT=${2:-} hh scripts/MVP/strategy/manage.js | tee -a .dryrun/$SYMBOL-rewards.log | grep -E '^Swap |^  tx:|Error' | sed 's/^/    /'
}

VAULT=$(cfg contracts BoringVault); MGR=$(cfg contracts Manager); STOCK=$(cfg config baseAsset); SUPERVAULT=$(cfg config superVault)
OWNER=$(cfg config owner); STRATEGIST=$(cfg config strategist)
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; SUP=0x2c71f70e2Ec720AE061Ae7E0316fC9654d94f417
imp $OWNER $STRATEGIST

echo "=== $SYMBOL: swap decoder and new root ==="
hh scripts/MVP/08_deploySwapDecoder.js | grep -E 'deployed at|recorded'
WRITE_ONLY=1 hh scripts/MVP/config/setManageRoot.js | grep -E 'leafs, root'
ROOT=$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["metadata"]["ManageRoot"])' "${DEPLOYMENT_FILE%.json}-leafs.json")
echo "live root $(c $MGR 'manageRoot(address)(bytes32)' $STRATEGIST)"
echo "owner Safe sets the new root: $(ok $OWNER --gas-limit 100000 $MGR 'setManageRoot(address,bytes32)' $STRATEGIST $ROOT)  now $(c $MGR 'manageRoot(address)(bytes32)' $STRATEGIST)"

echo; echo "=== Reward conversion ==="
cast rpc -r $FORK anvil_dealERC20 $USDC $VAULT $(cast to-hex 25000000) >/dev/null
echo "vault holds $(num $USDC 'balanceOf(address)(uint256)' $VAULT) USDC units, $(num $STOCK 'balanceOf(address)(uint256)' $VAULT) stock units"
echo "  swap all USDC into the stock:"; FROM=usdc manage swap
echo "vault holds $(num $USDC 'balanceOf(address)(uint256)' $VAULT) USDC units, $(num $STOCK 'balanceOf(address)(uint256)' $VAULT) stock units"
STOCK_HELD=$(num $STOCK 'balanceOf(address)(uint256)' $VAULT)

if cast rpc -r $FORK anvil_dealERC20 $SUP $VAULT $(cast to-hex 1000000000000000000000) >/dev/null 2>&1 && [ "$(num $SUP 'balanceOf(address)(uint256)' $VAULT)" != "0" ]; then
  echo "vault holds $(num $SUP 'balanceOf(address)(uint256)' $VAULT) sUP units"
  echo "  request the redeem of all sUP:"; manage redeemUP
  echo "pending sUP redeem: $(num $SUP 'pendingRedeemRequest(uint256,address)(uint256)' 0 $VAULT)"
  echo "  cancel it:"; manage cancelUP
  echo "pending cancel: $(c $SUP 'pendingCancelRedeemRequest(uint256,address)(bool)' 0 $VAULT)"
else
  echo "could not deal sUP on this fork; skipped the sUP redeem"
fi

echo; echo "=== The old leafs still verify ==="
if [ "$STOCK_HELD" != "0" ]; then
  HUMAN=$(python3 -I -c 'import sys; n, d = int(sys.argv[1]), int(sys.argv[2]); print(f"{n // 10**d}.{n % 10**d:0{d}d}")' $STOCK_HELD $(num $STOCK 'decimals()(uint8)'))
  echo "  deposit the swapped stock into the SuperVault:"; manage deposit $HUMAN
  echo "vault holds $(num $SUPERVAULT 'balanceOf(address)(uint256)' $VAULT) SuperVault shares"
fi
echo "approve USDC to the strategist (no leaf): $(ok $STRATEGIST --gas-limit 500000 $MGR 'manageVaultWithMerkleVerification(bytes32[][],address[],address[],bytes[],uint256[])' '[[]]' "[$(cfg contracts Decoder)]" "[$USDC]" "[$(cast calldata 'approve(address,uint256)' $STRATEGIST 1)]" '[0]') (want reverted)"
