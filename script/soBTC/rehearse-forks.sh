#!/usr/bin/env bash
# HISTORICAL: rehearses the original Nov 13 2026 rollout (cbBTC on Base). Base was redeployed with
# WBTC on Nov 16; rehearse that with rehearse-base-wbtc.sh. This script no longer matches the config.
# Rehearses the whole soBTC rollout on LOCAL anvil forks of Ethereum and Base, then uses it:
#   deploy x2 -> connect x2 -> handover x2 ->
#   cbBTC deposit on Base -> WBTC depositAndBridge on Ethereum (delivered on Base) ->
#   cbBTC withdraw on Base -> shares Base -> Ethereum -> WBTC withdraw on Ethereum -> shares back ->
#   rate update on both accountants -> negative checks -> check.
# LayerZero hops send on the source fork (proving the DVN/executor config quotes and sends) and
# deliver the PacketSent message to the destination teller by impersonating the endpoint. The
# deployer, Safes, solver Safes and token holders are impersonated. Nothing is sent to a real chain.
#
#   anvil --fork-url $BASE_RPC_URL    --port 8546
#   anvil --fork-url $MAINNET_RPC_URL --port 8548
#   bash script/soBTC/rehearse-forks.sh
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd); cd "$REPO"

BASE=http://127.0.0.1:8546; ETH=http://127.0.0.1:8548
[ "$(cast chain-id -r $BASE)" = 8453 ] && [ "$(cast chain-id -r $ETH)" = 1 ] || { echo "start the Base and Ethereum forks first"; exit 1; }

DEPLOYER=0x3B694d634981Ace4B64a27c48bffe19f1447779B
EP=0x1a44076050125825900e736c501f859c50fE728c
ETH_SAFE=0x6B26fAF3AD822695127B29ad242ac4B33D336F42; BASE_SAFE=0x5Eb1864D49ba5CeACc79CA861C20FcB922b5Eff3
RATE_UPDATER=0xBE7cDa9d1F046e90A898d01F686f4176b0d8b33F
WBTC=0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; CBBTC=0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf
WBTC_HOLDER=0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8   # Aave v3 aWBTC
CBBTC_HOLDER=0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb  # Morpho Blue on Base
NATIVE=0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
USER=0x000000000000000000000000000000000000bEEF
ONE=100000000  # 1 BTC / 1 soBTC (8 decimals)

mkdir -p .dryrun
export SOBTC_ETHEREUM_RECORD=.dryrun/soBTC-eth-rehearsal.json SOBTC_BASE_RECORD=.dryrun/soBTC-base-rehearsal.json
rm -f "$SOBTC_ETHEREUM_RECORD" "$SOBTC_BASE_RECORD"
export BASE_RPC_URL=$BASE MAINNET_RPC_URL=$ETH SOBTC_SENDER="--unlocked --sender $DEPLOYER"

imp() { local r=$1 x; shift; for x in "$@"; do cast rpc -r $r anvil_impersonateAccount $x >/dev/null; cast rpc -r $r anvil_setBalance $x 0x56BC75E2D63100000 >/dev/null; done; }
send() { local r=$1 from=$2; shift 2; cast send -r $r --unlocked --from $from "$@" --json; }
ok() { python3 -I -c 'import json,sys;print("succeeded" if json.load(sys.stdin)["status"]=="0x1" else "REVERTED")'; }
c() { cast call -r "$@"; }
num() { c "$@" | awk '{print $1}'; }
rec() { python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
btc() { python3 -I -c 'import sys;print(f"{int(sys.argv[1])/1e8:.8f}")' "$1"; }
step() { bash script/soBTC/sobtc.sh "$@" 2>&1 | grep -E "Error|revert|soBTC|SolverSafe|RolesAuthority |BoringVault |Accountant |LayerZeroTeller |Manager |BoringQueue |BoringSolver |Gas used|ETH paid|^Estimated" || true; }

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
deliver() {  # deliver <dst rpc> <dst teller> <src eid> <src teller> <receipt json>
  local r=$1 t=$2 eid=$3 src=$4 nonce guid msg
  read -r nonce guid msg <<< "$(packet <<< "$5")"
  imp $r $EP
  send $r $EP $t 'lzReceive((uint32,bytes32,uint64),bytes32,bytes,address,bytes)' \
    "($eid,$(cast to-uint256 $src),$nonce)" $guid $msg $DEPLOYER 0x --gas-limit 300000 | ok
}
bridge() {  # bridge <rpc> <teller> <from> <shares> <dst eid> -> receipt json
  local wc fee; wc=$(cast abi-encode 'f(uint32)' $5)
  fee=$(num $1 $2 'previewFee(uint96,address,bytes,address)(uint256)' $4 $3 $wc $NATIVE)
  send $1 $3 $2 'bridge(uint96,address,bytes,address,uint256)' $4 $3 $wc $NATIVE $fee --value $fee --gas-limit 600000
}
REQ_T='(uint96,address,address,uint128,uint128,uint40,uint24,uint24)'
withdraw() {  # withdraw <rpc> <queue> <solver> <teller> <vault> <asset> <solver safe> <shares> -> prints result
  local r=$1 q=$2 s=$3 t=$4 v=$5 a=$6 ss=$7 sh=$8 rid req a0
  send $r $USER $v 'approve(address,uint256)' $q $sh >/dev/null
  echo "  request $(btc $sh) soBTC: $(send $r $USER $q 'requestOnChainWithdraw(address,uint128,uint16,uint24)' $a $sh 1 259200 --gas-limit 400000 | ok)"
  rid=$(c $r $q 'getRequestIds()(bytes32[])' | tr -d '[]' | awk -F', ' '{print $NF}')
  req=$(c $r $q "getOnChainWithdraw(bytes32)($REQ_T)" $rid | sed 's/ \[[^]]*\]//g')
  cast rpc -r $r evm_increaseTime 130 >/dev/null; cast rpc -r $r evm_mine >/dev/null
  imp $r 0x000000000000000000000000000000000000dEaD $ss
  echo "  solve by a stranger: $(send $r 0x000000000000000000000000000000000000dEaD $s "boringRedeemSolve($REQ_T[],address,bool)" "[$req]" $t true --gas-limit 1000000 | ok) (want REVERTED)"
  a0=$(num $r $a 'balanceOf(address)(uint256)' $USER)
  echo "  solve by the solver Safe: $(send $r $ss $s "boringRedeemSolve($REQ_T[],address,bool)" "[$req]" $t true --gas-limit 1000000 | ok)  user got $(btc $(( $(num $r $a 'balanceOf(address)(uint256)' $USER) - a0 ))) $(c $r $a 'symbol()(string)')"
}

echo "=== 1. Deploy on both forks"
imp $ETH $DEPLOYER; imp $BASE $DEPLOYER
step deploy mainnet --broadcast
step deploy base --broadcast
EA=$SOBTC_ETHEREUM_RECORD; BA=$SOBTC_BASE_RECORD
ET=$(rec $EA LayerZeroTeller); EV=$(rec $EA BoringVault); EQ=$(rec $EA BoringQueue); ES=$(rec $EA BoringSolver); ESS=$(rec $EA SolverSafe); EACC=$(rec $EA Accountant)
BT=$(rec $BA LayerZeroTeller); BV=$(rec $BA BoringVault); BQ=$(rec $BA BoringQueue); BS=$(rec $BA BoringSolver); BSS=$(rec $BA SolverSafe); BACC=$(rec $BA Accountant)

echo "=== 2. Connect and hand over"
step connect mainnet --broadcast
step connect base --broadcast
step handover mainnet --broadcast
step handover base --broadcast
echo "deployer locked out: Ethereum $(c $ETH --from $DEPLOYER $EV 'setBeforeTransferHook(address)' $DEPLOYER >/dev/null 2>&1 && echo NO || echo yes), Base $(c $BASE --from $DEPLOYER $BV 'setBeforeTransferHook(address)' $DEPLOYER >/dev/null 2>&1 && echo NO || echo yes)"

echo "=== 3. Base: deposit 1 cbBTC"
imp $BASE $CBBTC_HOLDER $USER
send $BASE $CBBTC_HOLDER $CBBTC 'transfer(address,uint256)' $USER $((2 * ONE)) >/dev/null
send $BASE $USER $CBBTC 'approve(address,uint256)' $BV $((2 * ONE)) >/dev/null
echo "deposit: $(send $BASE $USER $BT 'deposit(address,uint256,uint256)' $CBBTC $ONE $ONE --gas-limit 400000 | ok)  shares $(btc $(num $BASE $BV 'balanceOf(address)(uint256)' $USER)) (want 1)"
echo "minimumMint above the quote: $(send $BASE $USER $BT 'deposit(address,uint256,uint256)' $CBBTC $ONE $((ONE + 1)) --gas-limit 400000 | ok) (want REVERTED)"
echo "depositAndBridge on Base is not public: $(send $BASE $USER $BT 'depositAndBridge(address,uint256,uint256,address,bytes,address,uint256)' $CBBTC $ONE 0 $USER $(cast abi-encode 'f(uint32)' 30101) $NATIVE 0 --gas-limit 600000 | ok) (want REVERTED)"

echo "=== 4. Ethereum: depositAndBridge 0.5 WBTC to Base"
imp $ETH $WBTC_HOLDER $USER
send $ETH $WBTC_HOLDER $WBTC 'transfer(address,uint256)' $USER $ONE >/dev/null
send $ETH $USER $WBTC 'approve(address,uint256)' $EV $ONE >/dev/null
WC=$(cast abi-encode 'f(uint32)' 30184)
FEE=$(num $ETH $ET 'previewFee(uint96,address,bytes,address)(uint256)' 0 $USER $WC $NATIVE)
R=$(send $ETH $USER $ET 'depositAndBridge(address,uint256,uint256,address,bytes,address,uint256)' $WBTC $((ONE / 2)) 0 $USER $WC $NATIVE $FEE --value $FEE --gas-limit 800000)
echo "send on Ethereum: $(ok <<< "$R")  fee $FEE wei  Ethereum vault WBTC $(btc $(num $ETH $WBTC 'balanceOf(address)(uint256)' $EV))  Ethereum supply $(num $ETH $EV 'totalSupply()(uint256)')"
echo "deliver on Base: $(deliver $BASE $BT 30101 $ET "$R")  user Base shares $(btc $(num $BASE $BV 'balanceOf(address)(uint256)' $USER)) (want 1.5)"

echo "=== 5. Base: withdraw 0.3 soBTC as cbBTC"
withdraw $BASE $BQ $BS $BT $BV $CBBTC $BSS $((3 * ONE / 10))

echo "=== 6. Base -> Ethereum 0.4 soBTC, withdraw 0.4 as WBTC on Ethereum"
R=$(bridge $BASE $BT $USER $((4 * ONE / 10)) 30101); echo "send on Base: $(ok <<< "$R")"
echo "deliver on Ethereum: $(deliver $ETH $ET 30184 $BT "$R")  user Ethereum shares $(btc $(num $ETH $EV 'balanceOf(address)(uint256)' $USER))"
withdraw $ETH $EQ $ES $ET $EV $WBTC $ESS $((4 * ONE / 10))
echo "withdraw more WBTC than the Ethereum vault holds (0.1 left):"
send $ETH $WBTC_HOLDER $WBTC 'transfer(address,uint256)' $USER 1 >/dev/null
R=$(bridge $BASE $BT $USER $((2 * ONE / 10)) 30101); deliver $ETH $ET 30184 $BT "$R" >/dev/null
send $ETH $USER $EV 'approve(address,uint256)' $EQ $((2 * ONE / 10)) >/dev/null
send $ETH $USER $EQ 'requestOnChainWithdraw(address,uint128,uint16,uint24)' $WBTC $((2 * ONE / 10)) 1 259200 --gas-limit 400000 >/dev/null
RID=$(c $ETH $EQ 'getRequestIds()(bytes32[])' | tr -d '[]' | awk -F', ' '{print $NF}')
REQ=$(c $ETH $EQ "getOnChainWithdraw(bytes32)($REQ_T)" $RID | sed 's/ \[[^]]*\]//g')
cast rpc -r $ETH evm_increaseTime 130 >/dev/null; cast rpc -r $ETH evm_mine >/dev/null
echo "  solve 0.2 against 0.1 WBTC: $(send $ETH $ESS $ES "boringRedeemSolve($REQ_T[],address,bool)" "[$REQ]" $ET true --gas-limit 1000000 | ok) (want REVERTED)"
S0=$(num $ETH $EV 'balanceOf(address)(uint256)' $USER)
echo "  user cancels: $(send $ETH $USER $EQ 'cancelOnChainWithdrawUsingRequestId(bytes32)' $RID --gas-limit 300000 | ok)  shares back $(btc $(( $(num $ETH $EV 'balanceOf(address)(uint256)' $USER) - S0 )))"

echo "=== 7. Ethereum -> Base 0.2 soBTC"
R=$(bridge $ETH $ET $USER $((2 * ONE / 10)) 30184); echo "send on Ethereum: $(ok <<< "$R")"
echo "deliver on Base: $(deliver $BASE $BT 30101 $ET "$R")  user Base shares $(btc $(num $BASE $BV 'balanceOf(address)(uint256)' $USER)) (want 0.8)"

echo "=== 8. Rate update (+0.01%) on both accountants from the rate updater"
for side in "$ETH $EACC" "$BASE $BACC"; do
  read -r r a <<< "$side"
  cast rpc -r $r evm_increaseTime 1001 >/dev/null; cast rpc -r $r evm_mine >/dev/null; imp $r $RATE_UPDATER
  echo "$(cast chain-id -r $r): $(send $r $RATE_UPDATER $a 'updateExchangeRate(uint96)' 100010000 --gas-limit 200000 | ok)  rate $(c $r $a 'getRate()(uint256)')  paused $(c $r $a 'accountantState()(address,uint96,uint128,uint128,uint96,uint16,uint16,uint64,bool,uint24,uint16,uint16)' | sed -n 9p)"
done

echo "=== 9. Negative checks"
echo "message from an unknown sender: $(imp $BASE $EP; send $BASE $EP $BT 'lzReceive((uint32,bytes32,uint64),bytes32,bytes,address,bytes)' "(30101,$(cast to-uint256 $USER),999)" 0x$(printf '%064x' 1) 0x$(printf '%064x' 1) $DEPLOYER 0x --gas-limit 300000 2>/dev/null | ok || echo REVERTED) (want REVERTED)"
echo "WBTC deposit on Base: $(c $BASE $BT 'assetData(address)(bool,bool,uint16)' $WBTC | head -1) (want false)"
echo "stranger updates the rate: $(imp $BASE $USER; send $BASE $USER $BACC 'updateExchangeRate(uint96)' 100020000 --gas-limit 200000 2>/dev/null | ok || echo REVERTED) (want REVERTED)"

echo "=== 10. Checks against the forks"
bash script/soBTC/sobtc.sh check
