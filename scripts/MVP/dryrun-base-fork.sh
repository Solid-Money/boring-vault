#!/usr/bin/env bash
# Dry run of a soEUR deployment (qa or prod settings) against a LOCAL anvil fork of Base: the full
# runner, a deposit, a withdrawal processed by the solver operator, a rate update, then the ownership
# handoff. Works on a scratch copy of the record, signs with anvil's public test key and impersonates
# the operator accounts. Nothing is sent to real Base.
#
# 1. In one terminal:  anvil --fork-url https://mainnet.base.org --port 8545
# 2. In another:       bash scripts/MVP/dryrun-base-fork.sh qa|prod
set -euo pipefail

ENV=${1:-}
case "$ENV" in qa|prod) ;; *) echo "Usage: bash scripts/MVP/dryrun-base-fork.sh qa|prod" >&2; exit 1 ;; esac
REPO=$(cd "$(dirname "$0")/../.." && pwd)
FORK=http://127.0.0.1:8545
EURC=0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42
A0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
USER=0x000000000000000000000000000000000000bEEF  # depositor, impersonated
cd "$REPO"
[ "$(cast chain-id -r $FORK 2>/dev/null)" = "8453" ] || { echo "fork not up or not Base"; exit 1; }

# Scratch record: the environment's settings, nothing deployed, the test key as deployer.
mkdir -p .dryrun
export DEPLOYMENT=$ENV DEPLOYMENT_FILE=$REPO/.dryrun/$ENV.json LOG=$REPO/.dryrun/$ENV.log
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
bash scripts/MVP/deploy-base.sh "$ENV" 2>&1 | grep -E '^>>>|STOPPED|Deployment:|deployed at'

VAULT=$(cfg contracts BoringVault); TELLER=$(cfg contracts Teller); QUEUE=$(cfg contracts BoringQueue)
SOLVER=$(cfg contracts BoringSolver); ACC=$(cfg contracts Accountant)
OPERATOR=$(cfg config solverOperator); UPDATER=$(cfg config rateUpdater); STRATEGIST=$(cfg config strategist)
c() { cast call -r $FORK "$@" 2>/dev/null; }
imp() { for a in "$@"; do cast rpc -r $FORK anvil_impersonateAccount $a >/dev/null; cast rpc -r $FORK anvil_setBalance $a 0x56BC75E2D63100000 >/dev/null; done; }
ok() { cast send -r $FORK --unlocked --from "$@" 2>&1 | grep -qE '^status +1' && echo succeeded || echo reverted; }
warp() { cast rpc -r $FORK evm_increaseTime $1 >/dev/null; cast rpc -r $FORK evm_mine >/dev/null; }
imp $USER $OPERATOR $UPDATER $STRATEGIST

echo; echo "=== Deposit 10 EURC, withdraw 5 $ENV soEUR through the queue and solver ==="
cast rpc -r $FORK anvil_dealERC20 $EURC $USER $(cast to-hex 10000000) >/dev/null 2>&1 || \
  cast rpc -r $FORK anvil_setStorageAt $EURC $(cast index address $USER 9) $(cast to-uint256 10000000) >/dev/null
echo "approve: $(ok $USER --gas-limit 100000 $EURC 'approve(address,uint256)' $VAULT 10000000)  deposit: $(ok $USER --gas-limit 300000 $TELLER 'deposit(address,uint256,uint256)' $EURC 10000000 9900000)  shares: $(c $VAULT 'balanceOf(address)(uint256)' $USER)"
echo "native ETH deposit: $(ok $USER --value 1000 --gas-limit 300000 $TELLER 'deposit(address,uint256,uint256)' 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE 1000 0) (want reverted)"
echo "request: $(ok $USER --gas-limit 100000 $VAULT 'approve(address,uint256)' $QUEUE 5000000)/$(ok $USER --gas-limit 400000 $QUEUE 'requestOnChainWithdraw(address,uint128,uint16,uint24)' $EURC 5000000 1 259200)"
RID=$(c $QUEUE 'getRequestIds()(bytes32[])' | tr -d '[]' | awk -F', ' '{print $NF}')
REQ=$(c $QUEUE 'getOnChainWithdraw(bytes32)((uint96,address,address,uint128,uint128,uint40,uint24,uint24))' $RID | sed 's/ \[[^]]*\]//g')
warp 121
EB=$(c $EURC 'balanceOf(address)(uint256)' $USER | awk '{print $1}')
echo "solver operator processes it: $(ok $OPERATOR --gas-limit 1000000 $SOLVER 'boringRedeemSolve((uint96,address,address,uint128,uint128,uint40,uint24,uint24)[],address,bool)' "[$REQ]" $TELLER false)  user received $(( $(c $EURC 'balanceOf(address)(uint256)' $USER | awk '{print $1}') - EB )) EURC units"

echo; echo "=== Rate update ==="
warp 1001
echo "from the rate updater: $(ok $UPDATER --gas-limit 200000 $ACC 'updateExchangeRate(uint96)' 1000000)"
if [ "$(echo $STRATEGIST | tr 'A-F' 'a-f')" != "$(echo $UPDATER | tr 'A-F' 'a-f')" ]; then
  warp 1001; echo "from the strategist: $(ok $STRATEGIST --gas-limit 200000 $ACC 'updateExchangeRate(uint96)' 1000000) (want reverted)"
fi

echo; echo ">>> config/transferOwnership.js"
npx hardhat run scripts/MVP/config/transferOwnership.js --network base --no-compile 2>&1 | grep -E 'New owner|EOA|verified|WARNING|complete|Error' || true
echo "old deployer locked out: $(cast call -r $FORK --from $A0 $TELLER 'updateAssetData(address,bool,bool,uint16)' $EURC true true 0 >/dev/null 2>&1 && echo 'NO, still has access' || echo yes)"
bash scripts/MVP/deploy-base.sh "$ENV" --check 2>&1 | sed -n '/=== Checks/,$p'
