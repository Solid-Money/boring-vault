#!/usr/bin/env bash
# Dry run of one vault's deployment (VAULT_SYMBOL, soEUR when unset; qa or prod settings) against a LOCAL
# anvil fork of Base: the full runner, a deposit, a withdrawal processed by the solver operator, a
# rate update, then the ownership handoff. For a stock vault it also runs the strategy: the
# strategist deposits into the SuperVault, requests and cancels a redeem, and the Merkl claim decodes
# to its leaf. Works on a scratch copy of the record, signs with anvil's public test key and
# impersonates the operator accounts. Nothing is sent to real Base.
#
# The stock tokens are B20 precompiles, so the fork needs anvil 1.8.4 or later with Base enabled.
# Keep forge itself at 1.5.x: newer forge prints remappings hardhat-foundry rejects. foundryup
# --install v1.8.7 then foundryup --use stable leaves the newer anvil in ~/.foundry/versions/v1.8.7.
# 1. In one terminal:  ~/.foundry/versions/v1.8.7/anvil --fork-url https://mainnet.base.org --port 8545 --network base
# 2. In another:       VAULT_SYMBOL=soNVDA bash scripts/MVP/dryrun-base-fork.sh qa|prod
set -euo pipefail

ENV=${1:-}
case "$ENV" in qa|prod) ;; *) echo "Usage: bash scripts/MVP/dryrun-base-fork.sh qa|prod" >&2; exit 1 ;; esac
REPO=$(cd "$(dirname "$0")/../.." && pwd)
FORK=http://127.0.0.1:8545
A0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
USER=0x000000000000000000000000000000000000bEEF  # depositor, impersonated
cd "$REPO"
[ "$(cast chain-id -r $FORK 2>/dev/null)" = "8453" ] || { echo "fork not up or not Base"; exit 1; }

# Scratch record: the environment's settings, nothing deployed, the test key as deployer.
mkdir -p .dryrun
NAME=${VAULT_SYMBOL:-soEUR}-$ENV
export DEPLOYMENT=$ENV DEPLOYMENT_FILE=$REPO/.dryrun/$NAME.json LOG=$REPO/.dryrun/$NAME.log
REAL=$(env -u DEPLOYMENT_FILE node -e "console.log(require('./scripts/MVP/deployment').load().file)")
python3 -I - "$REAL" "$DEPLOYMENT_FILE" "$A0" <<'EOF'
import json, sys
src, dst, deployer = sys.argv[1:]
d = json.load(open(src))
d["config"]["deployer"] = deployer
d["contracts"], d["done"] = {}, []
json.dump(d, open(dst, "w"), indent=2)
EOF
cfg() { python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]].get(sys.argv[3]) or "")' "$DEPLOYMENT_FILE" "$@"; }

# Every hardhat network in the repo config points at the local fork.
export PRIVATE_KEY=$K0 BASE_RPC_URL=$FORK MAINNET_RPC_URL=$FORK FUSE_RPC_URL=$FORK YES=1
bash scripts/MVP/deploy-base.sh "$ENV" 2>&1 | grep -E '^>>>|STOPPED|Deployment:|deployed at|Base asset|leafs, root'

VAULT=$(cfg contracts BoringVault); TELLER=$(cfg contracts Teller); QUEUE=$(cfg contracts BoringQueue)
SOLVER=$(cfg contracts BoringSolver); ACC=$(cfg contracts Accountant)
OPERATOR=$(cfg config solverOperator); UPDATER=$(cfg config rateUpdater); STRATEGIST=$(cfg config strategist)
BASE=$(cfg config baseAsset); SUPERVAULT=$(cfg config superVault); MGR=$(cfg contracts Manager)
c() { cast call -r $FORK "$@" 2>/dev/null; }
num() { c "$@" | awk '{print $1}'; }
imp() { for a in "$@"; do cast rpc -r $FORK anvil_impersonateAccount $a >/dev/null; cast rpc -r $FORK anvil_setBalance $a 0x56BC75E2D63100000 >/dev/null; done; }
ok() { cast send -r $FORK --unlocked --from "$@" 2>&1 | grep -qE '^status +1' && echo succeeded || echo reverted; }
warp() { cast rpc -r $FORK evm_increaseTime $1 >/dev/null; cast rpc -r $FORK evm_mine >/dev/null; }
imp $USER $OPERATOR $UPDATER $STRATEGIST
SYM=$(c $BASE 'symbol()(string)' | tr -d '"'); ONE=$((10 ** $(num $BASE 'decimals()(uint8)')))
manage() {  # one strategy action through the Manager, as the impersonated strategist
  STRATEGIST_UNLOCKED=1 ACTION=$1 AMOUNT=${2:-} npx hardhat run scripts/MVP/strategy/manage.js --network base --no-compile 2>&1 \
    | grep -v deny_warnings | grep -qE '^  tx:' && echo succeeded || echo reverted
}

echo; echo "=== Deposit 10 $SYM, withdraw 5 $ENV $(cfg config vaultTokenSymbol) through the queue and solver ==="
cast rpc -r $FORK anvil_dealERC20 $BASE $USER $(cast to-hex $((10 * ONE))) >/dev/null 2>&1 || true
if [ "$(num $BASE 'balanceOf(address)(uint256)' $USER)" != "$((10 * ONE))" ] && [ -n "$SUPERVAULT" ]; then
  # B20 balances are not plain storage slots, so take the tokens from the SuperVault's strategy.
  HOLDER=$(c $SUPERVAULT 'strategy()(address)'); imp $HOLDER
  echo "fund depositor from holder $HOLDER: $(ok $HOLDER --gas-limit 200000 $BASE 'transfer(address,uint256)' $USER $((10 * ONE)))"
elif [ "$(num $BASE 'balanceOf(address)(uint256)' $USER)" != "$((10 * ONE))" ]; then
  cast rpc -r $FORK anvil_setStorageAt $BASE $(cast index address $USER 9) $(cast to-uint256 $((10 * ONE))) >/dev/null
fi
echo "approve: $(ok $USER --gas-limit 100000 $BASE 'approve(address,uint256)' $VAULT $((10 * ONE)))  deposit: $(ok $USER --gas-limit 300000 $TELLER 'deposit(address,uint256,uint256)' $BASE $((10 * ONE)) $((99 * ONE / 10)))  shares: $(c $VAULT 'balanceOf(address)(uint256)' $USER)"
echo "native ETH deposit: $(ok $USER --value 1000 --gas-limit 300000 $TELLER 'deposit(address,uint256,uint256)' 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE 1000 0) (want reverted)"
if [ -n "$SUPERVAULT" ]; then
  echo "strategist deposits 4 $SYM into the SuperVault: $(manage deposit 4)  vault holds $(num $SUPERVAULT 'balanceOf(address)(uint256)' $VAULT) SuperVault shares, $(num $BASE 'balanceOf(address)(uint256)' $VAULT) $SYM units liquid"
fi
echo "request: $(ok $USER --gas-limit 100000 $VAULT 'approve(address,uint256)' $QUEUE $((5 * ONE)))/$(ok $USER --gas-limit 400000 $QUEUE 'requestOnChainWithdraw(address,uint128,uint16,uint24)' $BASE $((5 * ONE)) 1 259200)"
RID=$(c $QUEUE 'getRequestIds()(bytes32[])' | tr -d '[]' | awk -F', ' '{print $NF}')
REQ=$(c $QUEUE 'getOnChainWithdraw(bytes32)((uint96,address,address,uint128,uint128,uint40,uint24,uint24))' $RID | sed 's/ \[[^]]*\]//g')
warp 121
EB=$(num $BASE 'balanceOf(address)(uint256)' $USER)
echo "solver operator processes it: $(ok $OPERATOR --gas-limit 1000000 $SOLVER 'boringRedeemSolve((uint96,address,address,uint128,uint128,uint40,uint24,uint24)[],address,bool)' "[$REQ]" $TELLER false)  user received $(( $(num $BASE 'balanceOf(address)(uint256)' $USER) - EB )) $SYM units"

if [ -n "$SUPERVAULT" ]; then
  echo; echo "=== Strategy ==="
  HALF=$(python3 -I -c 'import sys; n, d = int(sys.argv[1]) // 2, int(sys.argv[2]); print(f"{n // 10**d}.{n % 10**d:0{d}d}")' \
    $(num $SUPERVAULT 'balanceOf(address)(uint256)' $VAULT) $(num $SUPERVAULT 'decimals()(uint8)'))
  echo "request redeem of half the SuperVault shares: $(manage requestRedeem $HALF)  pending $(num $SUPERVAULT 'pendingRedeemRequest(uint256,address)(uint256)' 0 $VAULT) shares"
  echo "cancel it: $(manage cancel)  pending cancel: $(c $SUPERVAULT 'pendingCancelRedeemRequest(uint256,address)(bool)' 0 $VAULT)"
  echo "call with no leaf (approve the stock token to the strategist): $(ok $STRATEGIST --gas-limit 500000 $MGR 'manageVaultWithMerkleVerification(bytes32[][],address[],address[],bytes[],uint256[])' '[[]]' "[$(cfg contracts Decoder)]" "[$BASE]" "[$(cast calldata 'approve(address,uint256)' $STRATEGIST 1)]" '[0]') (want reverted)"
  for T in $(cfg config rewardTokens | tr -d "[]',"); do
    GOT=$(c $(cfg contracts Decoder) 'claim(address[],address[],uint256[],bytes32[][])(bytes)' "[$VAULT]" "[$T]" '[1]' '[[]]')
    echo "Merkl claim of $(c $T 'symbol()(string)') decodes to [vault, token]: $( [ "$(echo $GOT | tr 'A-F' 'a-f')" = "$(echo ${VAULT}${T#0x} | tr 'A-F' 'a-f')" ] && echo yes || echo "NO ($GOT)")"
  done
fi

echo; echo "=== Rate update ==="
warp 1001
echo "from the rate updater: $(ok $UPDATER --gas-limit 200000 $ACC 'updateExchangeRate(uint96)' $ONE)"
if [ "$(echo $STRATEGIST | tr 'A-F' 'a-f')" != "$(echo $UPDATER | tr 'A-F' 'a-f')" ]; then
  warp 1001; echo "from the strategist: $(ok $STRATEGIST --gas-limit 200000 $ACC 'updateExchangeRate(uint96)' $ONE) (want reverted)"
fi

echo; echo ">>> config/transferOwnership.js"
npx hardhat run scripts/MVP/config/transferOwnership.js --network base --no-compile 2>&1 | grep -E 'New owner|EOA|verified|WARNING|complete|Error' || true
echo "old deployer locked out: $(cast call -r $FORK --from $A0 $TELLER 'updateAssetData(address,bool,bool,uint16)' $BASE true true 0 >/dev/null 2>&1 && echo 'NO, still has access' || echo yes)"
bash scripts/MVP/deploy-base.sh "$ENV" --check 2>&1 | sed -n '/=== Checks/,$p'
