#!/usr/bin/env bash
# Dry run of the soEURC Base deployment against a LOCAL anvil fork of Base.
# Uses anvil's public default test accounts only. Nothing is sent to real Base.
#
# 1. In one terminal:  anvil --fork-url https://mainnet.base.org --port 8545
# 2. In another:       bash scripts/MVP/dryrun-base-fork.sh
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
FORK=http://127.0.0.1:8545
DRY=$REPO/.dryrun/MVP
EURC=0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42

# anvil default accounts (public test keys)
A0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80  # deployer + owner
# anvil's public accounts carry EIP-7702 code on Base mainnet and can misbehave as senders on a fork,
# so the solver operator is the real (codeless on Base) solver Safe address, impersonated.
A1=0xA7Fdc92eDa10eac8d6AfD3037d398929B57303D7                                                                       # solver Safe (impersonated)
A2=0x6B26fAF3AD822695127B29ad242ac4B33D336F42                                                                       # owner Safe (soETH multisig)
A3=0x90F79bf6EB2c4f870365E785982E1f101E93b906; K3=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6  # depositor

# Every hardhat network in the repo config points at the local fork.
export PRIVATE_KEY=$K0 BASE_RPC_URL=$FORK MAINNET_RPC_URL=$FORK FUSE_RPC_URL=$FORK
[ "$(cast chain-id -r $FORK)" = "8453" ] || { echo "fork not up or wrong chain"; exit 1; }

cd $REPO
NC=""  # compile once, then --no-compile
hh() { echo; echo ">>> $1"; npx hardhat run "$DRY/$1" --network base $NC 2>&1 | grep -v deny_warnings | tee $REPO/.dryrun/last.log; NC=--no-compile; }
grab() { grep -E "$1" $REPO/.dryrun/last.log | grep -oE '0x[0-9a-fA-F]{40}' | tail -1; }
c() { cast call -r $FORK "$@" 2>/dev/null; }
s() { local k=$1; shift; cast send -r $FORK --private-key $k "$@" >/dev/null; }

# Fresh copies of the branch's scripts; the only dry-run change is ownerAddress = deployer.
rm -rf $REPO/.dryrun && mkdir -p $REPO/.dryrun && cp -R scripts/MVP $DRY
sed -i '' "s/^const ownerAddress = .*/const ownerAddress = '$A0'/" $DRY/deployAll.js

fill() {  # replace '' // TODO(Base) placeholders with known addresses
  python3 -I - "$DRY" "$AUTH" "$VAULT" "$ACC" "$TELLER" "$MGR" "${QUEUE:-}" "${SOLVER:-}" "$A1" "$A2" <<'EOF'
import sys, re, pathlib
d, auth, vault, acc, teller, mgr, queue, solver, safe, owner = sys.argv[1:]
m = {'authorityAddress': auth, 'boringVault': vault, 'boringVaultAddress': vault, 'vaultAddress': vault,
     'accountant': acc, 'accountantAddress': acc, 'tellerAddress': teller, 'managerAddress': mgr,
     'boringQueueWithTrackingAddress': queue, 'boringQueueAddress': queue, 'boringSolverAddress': solver,
     'solverSafeAddress': safe, 'newOwner': owner}
for p in pathlib.Path(d).rglob('*.js'):
    s = p.read_text()
    s = re.sub(r"^(const (\w+) = )'' // TODO\(Base\).*$",
               lambda x: f"{x.group(1)}'{m[x.group(2)]}'" if m.get(x.group(2)) else x.group(0), s, flags=re.M)
    p.write_text(s)
EOF
}

hh deployAll.js
AUTH=$(grab '^RolesAuthority:'); VAULT=$(grab '^BoringVault:'); ACC=$(grab '^Accountant:'); TELLER=$(grab '^Teller:'); MGR=$(grab '^Manager:')
fill
hh 05_deployBoringQueue.js;  QUEUE=$(grab 'Queue With Tracking deployed'); fill
hh 06_deployBoringSolver.js; SOLVER=$(grab 'Boring Solver deployed');        fill
hh config/setRolesConfig.js
hh config/setSolverRoles.js
hh config/setBeforeTransferHook.js
hh config/configureTeller.js
hh config/setWithdrawAsset.js
echo; echo "Unfilled placeholders left: $(grep -rc --include='*.js' "'' // TODO(Base)" $DRY | awk -F: '{s+=$2} END {print s}')"

echo; echo "=== Wiring and roles ==="
for x in VAULT ACC TELLER MGR QUEUE SOLVER; do a=${!x}; echo "$x $a authority=$( [ "$(c $a 'authority()(address)')" = "$AUTH" ] && echo ok || echo WRONG)"; done
echo "vault name/symbol/decimals: $(c $VAULT 'name()(string)') $(c $VAULT 'symbol()(string)') $(c $VAULT 'decimals()(uint8)')"
echo "vault hook = teller: $( [ "$(c $VAULT 'hook()(address)')" = "$TELLER" ] && echo ok || echo WRONG)"
echo "accountant rate: $(c $ACC 'getRate()(uint256)')  base: $(c $ACC 'base()(address)')"
echo "teller vault/accountant/nativeWrapper: $(c $TELLER 'vault()(address)') $(c $TELLER 'accountant()(address)') $(c $TELLER 'nativeWrapper()(address)')"
echo "fee payout: $(c $ACC 'accountantState()(address,uint96,uint128,uint128,uint96,uint16,uint16,uint64,bool,uint24,uint16,uint16)' | head -1)"
pub() { c $AUTH 'isCapabilityPublic(address,bytes4)(bool)' $1 $2; }
echo "public deposit=$(pub $TELLER 0x0efe6a8b) depositWithPermit=$(pub $TELLER 0x3d935d9e) requestWithdraw=$(pub $QUEUE 0x6bb3b476)"
echo "teller can enter=$(c $AUTH 'canCall(address,address,bytes4)(bool)' $TELLER $VAULT 0x39d6ba32) exit=$(c $AUTH 'canCall(address,address,bytes4)(bool)' $TELLER $VAULT 0x18457e61)"
echo "EURC assetData: $(c $TELLER 'assetData(address)(bool,bool,uint16)' $EURC | tr '\n' ' ')  native: $(c $TELLER 'assetData(address)(bool,bool,uint16)' 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE | tr '\n' ' ')"

echo; echo "=== Deposit 100 EURC ==="
cast rpc -r $FORK anvil_dealERC20 $EURC $A3 $(cast to-hex 1000000000) >/dev/null 2>&1 || \
  cast rpc -r $FORK anvil_setStorageAt $EURC $(cast index address $A3 9) $(cast to-uint256 1000000000) >/dev/null
echo "user EURC: $(c $EURC 'balanceOf(address)(uint256)' $A3)"
s $K3 $EURC 'approve(address,uint256)' $VAULT 100000000
s $K3 $TELLER 'deposit(address,uint256,uint256)' $EURC 100000000 99000000
echo "user soEURC: $(c $VAULT 'balanceOf(address)(uint256)' $A3)  vault EURC: $(c $EURC 'balanceOf(address)(uint256)' $VAULT)"
echo -n "native deposit (must revert): "; cast send -r $FORK --private-key $K3 --value 1000 $TELLER 'deposit(address,uint256,uint256)' 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE 1000 0 >/dev/null 2>&1 && echo "DID NOT REVERT" || echo reverted

echo; echo "=== Withdraw 50 soEURC through queue + solver ==="
s $K3 $VAULT 'approve(address,uint256)' $QUEUE 50000000
s $K3 $QUEUE 'requestOnChainWithdraw(address,uint128,uint16,uint24)' $EURC 50000000 1 259200
RID=$(c $QUEUE 'getRequestIds()(bytes32[])' | tr -d '[]' | cut -d, -f1)
REQ=$(c $QUEUE 'getOnChainWithdraw(bytes32)((uint96,address,address,uint128,uint128,uint40,uint24,uint24))' $RID | sed 's/ \[[^]]*\]//g')
echo "request: $REQ"
cast rpc -r $FORK evm_increaseTime 121 >/dev/null; cast rpc -r $FORK evm_mine >/dev/null
EB=$(c $EURC 'balanceOf(address)(uint256)' $A3 | awk '{print $1}')
cast rpc -r $FORK anvil_impersonateAccount $A1 >/dev/null; cast rpc -r $FORK anvil_setBalance $A1 0x56BC75E2D63100000 >/dev/null
cast send -r $FORK --unlocked --from $A1 --gas-limit 1000000 $SOLVER 'boringRedeemSolve((uint96,address,address,uint128,uint128,uint40,uint24,uint24)[],address,bool)' "[$REQ]" $TELLER false >/dev/null
EA=$(c $EURC 'balanceOf(address)(uint256)' $A3 | awk '{print $1}')
echo "user EURC received: $((EA-EB))  soEURC left: $(c $VAULT 'balanceOf(address)(uint256)' $A3)  open requests: $(c $QUEUE 'getRequestIds()(bytes32[])')"

echo; echo "=== Handoff is refused while the Safe does not exist on Base ==="
npx hardhat run $DRY/config/transferOwnership.js --network base --no-compile 2>&1 | grep -oE "has no code on this chain[^\"]*" | head -1 || true

echo; echo "=== Recreate the owner Safe at the same address and fix its signers (rehearses the Base Safe steps) ==="
# Same createProxyWithNonce call that created 0x6B26 on Ethereum (tx 0xa29a4972…81a0), sent to the same factory.
SAFE_CREATE=0x1688f0b900000000000000000000000041675c099f32341bf84bfc5382af534df5c7461a000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000264b63e800d00000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000003000000000000000000000000bd89a1ce4dde368ffab0ec35506eece0b1ffdc540000000000000000000000000000000000000000000000000000000000000200000000000000000000000000fd0732dc9e303f09fcef3a7388ad10a83459ec99000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005afe7a11e700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000070000000000000000000000003b694d634981ace4b64a27c48bffe19f1447779b0000000000000000000000007ceabc27b1dc6a065fad85a86afbaf97f7692088000000000000000000000000de808bccef1325e37365aa350808f012ce09d2af0000000000000000000000005788e790adb0913fd8e837a7c509cb05ea8141e400000000000000000000000063a61a31f087295a2b3fbe6f546913ccbe8127e80000000000000000000000008f7ff15f3b8c9693ca81f75a20ea77a2900f2f0c00000000000000000000000094f4f3ea145dd3554dac5bd8e8bc7e014121903b0000000000000000000000000000000000000000000000000000000000000024fe51f64300000000000000000000000029fcb43b46531bca003ddc8fcb67ffe91900c7620000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
cast send -r $FORK --private-key $K3 --gas-limit 1000000 0x4e1dcf7ad4e460cfd30791ccc4f9c8a4f820ec67 $SAFE_CREATE >/dev/null
echo "recreated: $(c $A2 'getThreshold()(uint256)')-of-$(c $A2 'getOwners()(address[])')"
# On Base this is one Safe transaction signed by 3 of those 7: 0x3B69, 0x63A6 and one former signer.
cast rpc -r $FORK anvil_impersonateAccount $A2 >/dev/null; cast rpc -r $FORK anvil_setBalance $A2 0x56BC75E2D63100000 >/dev/null
ss() { cast send -r $FORK --unlocked --from $A2 --gas-limit 300000 $A2 "$@" >/dev/null; }
ss 'addOwnerWithThreshold(address,uint256)' 0x26F9A59F0F0e92e8a8d6f835d57657a3a3b51103 3
ss 'addOwnerWithThreshold(address,uint256)' 0x2B30BD61C63DA8E528935A8589866D0509c39a50 3
ss 'removeOwner(address,address,uint256)' 0x3B694d634981Ace4B64a27c48bffe19f1447779B 0x7Ceabc27B1dc6A065fAD85A86AFBaF97F7692088 3
ss 'removeOwner(address,address,uint256)' 0x3B694d634981Ace4B64a27c48bffe19f1447779B 0xdE808bccEf1325E37365aa350808F012Ce09d2AF 3
ss 'removeOwner(address,address,uint256)' 0x3B694d634981Ace4B64a27c48bffe19f1447779B 0x5788e790aDB0913Fd8E837a7C509CB05ea8141e4 3
ss 'removeOwner(address,address,uint256)' 0x63A61a31F087295a2b3fbE6F546913Ccbe8127e8 0x8f7FF15F3B8c9693CA81F75a20ea77a2900F2f0c 3
ss 'removeOwner(address,address,uint256)' 0x63A61a31F087295a2b3fbE6F546913Ccbe8127e8 0x94f4F3Ea145dd3554DAc5Bd8E8bC7E014121903b 3
echo "after fix:  $(c $A2 'getThreshold()(uint256)')-of-$(c $A2 'getOwners()(address[])')"

echo; echo ">>> config/transferOwnership.js"
npx hardhat run $DRY/config/transferOwnership.js --network base --no-compile 2>&1 | grep -v deny_warnings | grep -E 'tx:|SKIP|Skipping|complete|Error|verified' | sed 's/tx: 0x.*/tx sent/' || true
for x in AUTH VAULT ACC TELLER MGR QUEUE SOLVER; do a=${!x}; echo "$x owner=$( [ "$(c $a 'owner()(address)')" = "$A2" ] && echo 'new owner' || c $a 'owner()(address)')"; done
echo "old deployer locked out: $(cast call -r $FORK --from $A0 $TELLER 'updateAssetData(address,bool,bool,uint16)' $EURC true true 0 >/dev/null 2>&1 && echo 'NO, still has access' || echo yes)"
