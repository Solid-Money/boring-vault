#!/usr/bin/env bash
# Rehearses the Nov 16 2026 soBTC Base redeploy (cbBTC -> WBTC) on LOCAL anvil forks, against the
# live Ethereum soBTC stack (Safe-owned) and the live Base card:
#   deploy base -> connect base -> handover base -> Ethereum Safe batch -> Base switch batch ->
#   WBTC deposit on Base -> strategist bridges the vault's WBTC to the Ethereum vault (OFT send, via
#   the new Base manager's root) -> shares Base -> Ethereum -> WBTC withdraw on Ethereum ->
#   WBTC depositAndBridge Ethereum -> Base -> card delist batch -> negative checks -> check.
# LayerZero hops send on the source fork and deliver the PacketSent message on the destination
# fork by impersonating the endpoint. Safes, deployer, strategist and solver Safe are impersonated.
# Nothing is sent to a real chain.
#
#   anvil --fork-url $BASE_RPC_URL    --port 8546 --hardfork prague
#   anvil --fork-url $MAINNET_RPC_URL --port 8548
#   bash script/soBTC/rehearse-base-wbtc.sh
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd); cd "$REPO"
export FOUNDRY_OFFLINE=true

BASE=http://127.0.0.1:8546; ETH=http://127.0.0.1:8548
[ "$(cast chain-id -r $BASE)" = 8453 ] && [ "$(cast chain-id -r $ETH)" = 1 ] || { echo "start the Base and Ethereum forks first"; exit 1; }

DEPLOYER=0x3B694d634981Ace4B64a27c48bffe19f1447779B
EP=0x1a44076050125825900e736c501f859c50fE728c
ETH_SAFE=0x6B26fAF3AD822695127B29ad242ac4B33D336F42; BASE_SAFE=0x5Eb1864D49ba5CeACc79CA861C20FcB922b5Eff3
STRATEGIST=0x6f3334EC6355eD6f70100Cd1Cd6736505cd0F9b5
WBTC=0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599          # Ethereum WBTC
BWBTC=0x0555E30da8f98308EdB960aa94C0Db47230d2B9c         # Base WBTC OFT; also the Ethereum OFT adapter
CBBTC=0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf
OLD_VAULT=0xb5Fb6a807c1B35419CCC90480287305314D77B52; OLD_TELLER=0xBBd9100Be5712594B5db736e5280A4C0535Ee4Ec
CORE=0x47A5e832E1178726dd13AdD762774A704878AD98
BASE_DECODER=0x9141da076a7d7Ee616fc9Fe99e2e1B54A4cD271d    # shared Base decoder: approve, claimFees, OFT send
WBTC_HOLDER=0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8     # Aave v3 aWBTC
NATIVE=0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
USER=0x000000000000000000000000000000000000bEEF
ONE=100000000

mkdir -p .dryrun/batches
export SOBTC_ETHEREUM_RECORD=.dryrun/soBTC-eth-wbtc-rehearsal.json SOBTC_BASE_RECORD=.dryrun/soBTC-base-wbtc-rehearsal.json
export SOBTC_BATCH_DIR=.dryrun/batches
cp deployments/addresses/Mainnet/soBTC.json "$SOBTC_ETHEREUM_RECORD"; rm -f "$SOBTC_BASE_RECORD"
export BASE_RPC_URL=$BASE MAINNET_RPC_URL=$ETH SOBTC_SENDER="--unlocked --sender $DEPLOYER"

imp() { local r=$1 x; shift; for x in "$@"; do cast rpc -r $r anvil_impersonateAccount $x >/dev/null; cast rpc -r $r anvil_setBalance $x 0x56BC75E2D63100000 >/dev/null; done; }
send() { local r=$1 from=$2; shift 2; cast send -r $r --unlocked --from $from "$@" --json; }
ok() { python3 -I -c 'import json,sys;print("succeeded" if json.load(sys.stdin)["status"]=="0x1" else "REVERTED")'; }
try() { "$@" 2>/dev/null | ok || echo REVERTED; }
c() { cast call -r "$@"; }
num() { c "$@" | awk '{print $1}'; }
rec() { python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
btc() { python3 -I -c 'import sys;print(f"{int(sys.argv[1])/1e8:.8f}")' "$1"; }
step() { bash script/soBTC/sobtc.sh "$@" 2>&1 | grep -E "Error|revert|STOPPED|soBTC|RolesAuthority |BoringVault |Accountant |LayerZeroTeller |Manager |wrote|simulating|card at|Gas used" || true; }
batch_exec() {  # batch_exec <rpc> <safe> <batch json>
  python3 -I -c 'import json,sys;[print(t["to"],t["data"]) for t in json.load(open(sys.argv[1]))["transactions"]]' "$3" |
    while read -r to data; do echo "    $to $(send $1 $2 $to $data --gas-limit 2000000 | ok)"; done
}

PACKET_SENT=$(cast keccak 'PacketSent(bytes,bytes,address)')
packet() {
  python3 -I -c '
import json, sys
r = json.load(sys.stdin); topic = sys.argv[1]
for l in r["logs"]:
    if l["topics"][0] == topic:
        d = bytes.fromhex(l["data"][2:])
        off = int.from_bytes(d[0:32], "big"); ln = int.from_bytes(d[off:off+32], "big")
        p = d[off+32:off+32+ln]
        print(int.from_bytes(p[1:9], "big"), "0x" + p[81:113].hex(), "0x" + p[113:].hex()); break
else:
    sys.exit("no PacketSent")' "$PACKET_SENT"
}
deliver() {  # deliver <dst rpc> <dst oapp> <src eid> <src oapp> <receipt json>
  local r=$1 t=$2 eid=$3 src=$4 nonce guid msg
  read -r nonce guid msg <<< "$(packet <<< "$5")"
  imp $r $EP
  send $r $EP $t 'lzReceive((uint32,bytes32,uint64),bytes32,bytes,address,bytes)' \
    "($eid,$(cast to-uint256 $src),$nonce)" $guid $msg $DEPLOYER 0x --gas-limit 400000 | ok
}
bridge() {  # bridge <rpc> <teller> <from> <shares> <dst eid> -> receipt json
  local wc fee; wc=$(cast abi-encode 'f(uint32)' $5)
  fee=$(num $1 $2 'previewFee(uint96,address,bytes,address)(uint256)' $4 $3 $wc $NATIVE)
  send $1 $3 $2 'bridge(uint96,address,bytes,address,uint256)' $4 $3 $wc $NATIVE $fee --value $fee --gas-limit 600000
}
h() { cast keccak "$(python3 -I -c 'import sys;a,b=sorted([sys.argv[1].lower(),sys.argv[2].lower()]);print(a+b[2:])' "$1" "$2")"; }
REQ_T='(uint96,address,address,uint128,uint128,uint40,uint24,uint24)'

echo "=== 0. Live state"
echo "Ethereum soBTC supply $(num $ETH $(rec $SOBTC_ETHEREUM_RECORD BoringVault) 'totalSupply()(uint256)'), old Base vault supply $(num $BASE $OLD_VAULT 'totalSupply()(uint256)') (both want 0)"

echo "=== 1. Deploy, connect, hand over the WBTC stack on Base"
imp $BASE $DEPLOYER
step deploy base --broadcast
BA=$SOBTC_BASE_RECORD; EA=$SOBTC_ETHEREUM_RECORD
BT=$(rec $BA LayerZeroTeller); BV=$(rec $BA BoringVault); BACC=$(rec $BA Accountant); BM=$(rec $BA Manager)
ET=$(rec $EA LayerZeroTeller); EV=$(rec $EA BoringVault); EQ=$(rec $EA BoringQueue); ES=$(rec $EA BoringSolver); ESS=$(rec $EA SolverSafe)
echo "record has no queue: $(python3 -I -c 'import json,sys;print("BoringQueue" not in json.load(open(sys.argv[1])))' $BA)"
step connect base --broadcast
step handover base --broadcast

echo "=== 2. Base root: WBTC fee claim + OFT send of the vault's WBTC to the Ethereum vault"
APPROVE=$(cast sig 'approve(address,uint256)'); CLAIM=$(cast sig 'claimFees(address)'); SEND=$(cast sig 'send((uint32,bytes32,uint256,uint256,bytes,bytes,bytes),(uint256,uint256),address)')
L0=$(cast keccak $(cast abi-encode --packed 'f(address,address,bool,bytes4,address)' $BASE_DECODER $BWBTC false $APPROVE $BACC))
L1=$(cast keccak $(cast abi-encode --packed 'f(address,address,bool,bytes4,address)' $BASE_DECODER $BACC false $CLAIM $BWBTC))
EVL=$(echo $EV | tr 'A-F' 'a-f' | sed 's/0x//')
SENS=$(printf '%040x' 30101)000000000000000000000000${EVL:0:8}00000000${EVL:8:32}00000000
L2=$(cast keccak $(cast abi-encode --packed 'f(address,address,bool,bytes4,bytes)' $BASE_DECODER $BWBTC true $SEND 0x${SENS}$(echo $BV | tr 'A-F' 'a-f' | sed 's/0x//')))
N01=$(h $L0 $L1); ROOT=$(h $N01 $L2)
echo "Base root $ROOT"
export SOBTC_BASE_ROOT=$ROOT

echo "=== 3. Safe batches"
imp $ETH $ETH_SAFE; imp $BASE $BASE_SAFE
step batch ethereum
batch_exec $ETH $ETH_SAFE .dryrun/batches/eth-sobtc-base-wbtc.json
step batch base-switch
batch_exec $BASE $BASE_SAFE .dryrun/batches/base-sobtc-wbtc-switch.json
echo "Ethereum teller peer for Base: $(c $ETH $ET 'peers(uint32)(bytes32)' 30184) (want $BT)"

echo "=== 4. Base: deposit 1 WBTC"
imp $BASE $EP $USER
MSG=0x$(cast to-uint256 $USER | sed 's/0x//')$(printf '%016x' $((3 * ONE)))
echo "mint 3 Base WBTC to the user over the OFT: $(send $BASE $EP $BWBTC 'lzReceive((uint32,bytes32,uint64),bytes32,bytes,address,bytes)' "(30101,$(cast to-uint256 $BWBTC),999999)" 0x$(printf '%064x' 7) $MSG $DEPLOYER 0x --gas-limit 300000 | ok)"
send $BASE $USER $BWBTC 'approve(address,uint256)' $BV $((3 * ONE)) >/dev/null
echo "deposit: $(send $BASE $USER $BT 'deposit(address,uint256,uint256)' $BWBTC $ONE $ONE --gas-limit 400000 | ok)  shares $(btc $(num $BASE $BV 'balanceOf(address)(uint256)' $USER)) (want 1)"
echo "cbBTC deposit on the new teller: $(c $BASE $BT 'assetData(address)(bool,bool,uint16)' $CBBTC | head -1) (want false)"

echo "=== 5. Strategist bridges the Base vault's 1 WBTC to the Ethereum vault"
TO=$(cast to-uint256 $EV)
FEE=$(c $BASE $BWBTC 'quoteSend((uint32,bytes32,uint256,uint256,bytes,bytes,bytes),bool)((uint256,uint256))' "(30101,$TO,$ONE,$ONE,0x,0x,0x)" false | tr -d '()' | awk -F', ' '{print $1}' | awk '{print $1}')
cast rpc -r $BASE anvil_setBalance $BV 0x16345785D8A0000 >/dev/null   # 0.1 ETH in the vault for the fee
DATA=$(cast calldata 'send((uint32,bytes32,uint256,uint256,bytes,bytes,bytes),(uint256,uint256),address)' "(30101,$TO,$ONE,$ONE,0x,0x,0x)" "($FEE,0)" $BV)
imp $BASE $STRATEGIST
manage() { send $BASE $STRATEGIST $BM 'manageVaultWithMerkleVerification(bytes32[][],address[],address[],bytes[],uint256[])' "[[$1]]" "[$BASE_DECODER]" "[$BWBTC]" "[$2]" "[$FEE]" --gas-limit 800000; }
R=$(manage $N01 $DATA); echo "OFT send through the manager: $(ok <<< "$R")  Base vault WBTC left $(btc $(num $BASE $BWBTC 'balanceOf(address)(uint256)' $BV))"
E0=$(num $ETH $WBTC 'balanceOf(address)(uint256)' $EV)
echo "deliver on Ethereum: $(deliver $ETH $BWBTC 30184 $BWBTC "$R")  Ethereum vault WBTC +$(btc $(( $(num $ETH $WBTC 'balanceOf(address)(uint256)' $EV) - E0 ))) (want 1)"
BAD=$(cast calldata 'send((uint32,bytes32,uint256,uint256,bytes,bytes,bytes),(uint256,uint256),address)' "(30101,$(cast to-uint256 $USER),1,1,0x,0x,0x)" "($FEE,0)" $BV)
echo "strategist sends to another address: $(try manage $N01 $BAD) (want REVERTED)"

echo "=== 6. User: 0.4 soBTC Base -> Ethereum, withdraw as WBTC on Ethereum"
R=$(bridge $BASE $BT $USER $((4 * ONE / 10)) 30101); echo "send on Base: $(ok <<< "$R")"
echo "deliver on Ethereum: $(deliver $ETH $ET 30184 $BT "$R")  user Ethereum shares $(btc $(num $ETH $EV 'balanceOf(address)(uint256)' $USER)) (want 0.4)"
imp $ETH $USER
send $ETH $USER $EV 'approve(address,uint256)' $EQ $((4 * ONE / 10)) >/dev/null
echo "request: $(send $ETH $USER $EQ 'requestOnChainWithdraw(address,uint128,uint16,uint24)' $WBTC $((4 * ONE / 10)) 1 259200 --gas-limit 400000 | ok)"
RID=$(c $ETH $EQ 'getRequestIds()(bytes32[])' | tr -d '[]' | awk -F', ' '{print $NF}')
REQ=$(c $ETH $EQ "getOnChainWithdraw(bytes32)($REQ_T)" $RID | sed 's/ \[[^]]*\]//g')
cast rpc -r $ETH evm_increaseTime 130 >/dev/null; cast rpc -r $ETH evm_mine >/dev/null
imp $ETH $ESS; W0=$(num $ETH $WBTC 'balanceOf(address)(uint256)' $USER)
echo "solve by the solver Safe: $(send $ETH $ESS $ES "boringRedeemSolve($REQ_T[],address,bool)" "[$REQ]" $ET true --gas-limit 1000000 | ok)  user got $(btc $(( $(num $ETH $WBTC 'balanceOf(address)(uint256)' $USER) - W0 ))) WBTC"

echo "=== 7. Ethereum: depositAndBridge 0.5 WBTC to the new Base teller"
imp $ETH $WBTC_HOLDER
send $ETH $WBTC_HOLDER $WBTC 'transfer(address,uint256)' $USER $ONE >/dev/null
send $ETH $USER $WBTC 'approve(address,uint256)' $EV $ONE >/dev/null
WC=$(cast abi-encode 'f(uint32)' 30184)
FEE2=$(num $ETH $ET 'previewFee(uint96,address,bytes,address)(uint256)' 0 $USER $WC $NATIVE)
R=$(send $ETH $USER $ET 'depositAndBridge(address,uint256,uint256,address,bytes,address,uint256)' $WBTC $((ONE / 2)) 0 $USER $WC $NATIVE $FEE2 --value $FEE2 --gas-limit 800000)
echo "send on Ethereum: $(ok <<< "$R")"
echo "deliver on Base: $(deliver $BASE $BT 30101 $ET "$R")  user Base shares $(btc $(num $BASE $BV 'balanceOf(address)(uint256)' $USER)) (want 1.1)"

echo "=== 8. Card: delist the cbBTC soBTC"
step batch base-delist
batch_exec $BASE $BASE_SAFE .dryrun/batches/base-sobtc-cbbtc-delist.json

echo "=== 9. Negative checks"
echo "deposit into the old cbBTC teller: $(try send $BASE $USER $OLD_TELLER 'deposit(address,uint256,uint256)' $CBBTC 1 0 --gas-limit 300000) (want REVERTED)"
echo "old teller peer for Ethereum: $(c $BASE $OLD_TELLER 'peers(uint32)(bytes32)' 30101) (want 0)"
echo "Base teller bulkWithdraw by a stranger: $(try send $BASE $USER $BT 'bulkWithdraw(address,uint256,uint256,address)' $BWBTC 1 0 $USER --gas-limit 300000) (want REVERTED)"
echo "Base WBTC withdraws allowed: $(c $BASE $BT 'assetData(address)(bool,bool,uint16)' $BWBTC | sed -n 2p) (want false)"
echo "deployer locked out of Base: $(c $BASE --from $DEPLOYER $BV 'setBeforeTransferHook(address)' $DEPLOYER >/dev/null 2>&1 && echo NO || echo yes)"

echo "=== 10. Checks against the forks"
bash script/soBTC/sobtc.sh check
