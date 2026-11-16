#!/usr/bin/env bash
# soBTC on Ethereum + Base: deploy, connect, handover, checks.
#
#   bash script/soBTC/sobtc.sh deploy   mainnet|base [--broadcast]   vault stack, roles, deposits (+ queue, solver, solver Safe on mainnet), DVN config
#   bash script/soBTC/sobtc.sh connect  mainnet|base [--broadcast]   addChain(other chain's teller)
#   bash script/soBTC/sobtc.sh handover mainnet|base [--broadcast]   LayerZero delegate + ownership -> that chain's Safe
#   bash script/soBTC/sobtc.sh check                                 read-only checks on both chains
#   bash script/soBTC/sobtc.sh batch    ethereum|base-switch|base-delist   build a Safe batch (simulated as the Safe)
#
# Nov 16 2026, Base redeploy with WBTC (the cbBTC stack never took a deposit):
#   deploy base -> connect base -> handover base -> check ->
#   batch ethereum + batch base-switch (sign both) -> helm with the new soBTC -> batch base-delist (sign)
#
# Without --broadcast every step is a simulation against live state. Order:
#   deploy mainnet -> deploy base -> connect mainnet -> connect base -> check -> handover mainnet -> handover base -> check
#
# Needs PRIVATE_KEY (deployer 0x3B69), MAINNET_RPC_URL and BASE_RPC_URL in .env.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO"
# RPC URLs already in the environment win over .env (the fork rehearsal points them at anvil).
PRE_BASE=${BASE_RPC_URL:-}; PRE_ETH=${MAINNET_RPC_URL:-}
set -a; source .env; set +a
BASE_RPC_URL=${PRE_BASE:-$BASE_RPC_URL}; MAINNET_RPC_URL=${PRE_ETH:-$MAINNET_RPC_URL}

DIR=script/soBTC
# The checkout's nested submodules are partly uninitialised; never let forge try to install them.
export FOUNDRY_OFFLINE=true
export SOBTC_ETHEREUM_RECORD=${SOBTC_ETHEREUM_RECORD:-deployments/addresses/Mainnet/soBTC.json}
export SOBTC_BASE_RECORD=${SOBTC_BASE_RECORD:-deployments/addresses/Base/soBTC.json}
EP=0x1a44076050125825900e736c501f859c50fE728c
ETH_SAFE=0x6B26fAF3AD822695127B29ad242ac4B33D336F42; BASE_SAFE=0x5Eb1864D49ba5CeACc79CA861C20FcB922b5Eff3
DEPLOYER=0x3B694d634981Ace4B64a27c48bffe19f1447779B
NATIVE=0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE

die() { echo "STOPPED: $*" >&2; exit 1; }
rec() { python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }

rpc_for() { case "$1" in mainnet) echo "$MAINNET_RPC_URL" ;; base) echo "$BASE_RPC_URL" ;; *) die "chain must be mainnet or base" ;; esac; }

forge_run() {  # forge_run <script> <chain> [--broadcast]
  local flags=""
  if [ "${3:-}" = "--broadcast" ]; then flags="--broadcast --slow"; else echo "(simulation: nothing is sent; add --broadcast to send)"; fi
  # shellcheck disable=SC2086
  forge script "$DIR/$1" --rpc-url "$(rpc_for "$2")" ${SOBTC_SENDER:---private-key $PRIVATE_KEY} $flags
}

case "${1:-}" in
  deploy)
    if [ "${3:-}" != "--broadcast" ] && [ -z "${SOBTC_SENDER:-}" ]; then
      # A simulation writes its record to .dryrun/ (forge may only touch the repo), never the real one.
      mkdir -p .dryrun; T=$(date +%s)
      [ "$2" = mainnet ] && export SOBTC_ETHEREUM_RECORD=.dryrun/soBTC-eth-$T.json || export SOBTC_BASE_RECORD=.dryrun/soBTC-base-$T.json
    fi
    forge_run DeploySoBtc.s.sol "${2:-}" "${3:-}"
    ;;
  connect)  forge_run ConnectSoBtc.s.sol "${2:-}" "${3:-}" ;;
  handover) forge_run HandoverSoBtc.s.sol "${2:-}" "${3:-}" ;;
  batch)
    case "${2:-}" in
      ethereum) chain=mainnet; ev="" ;;
      base-switch|base-delist) chain=base; ev="--evm-version prague" ;;
      *) die "batch must be ethereum, base-switch or base-delist" ;;
    esac
    # shellcheck disable=SC2086
    SOBTC_BATCH=$2 forge script $DIR/SoBtcWbtcBatches.s.sol --rpc-url "$(rpc_for $chain)" $ev
    ;;

  check)
    c() { cast call -r "$@" 2>/dev/null; }
    same() { [ "$(echo "$1" | tr 'A-F' 'a-f')" = "$(echo "$2" | tr 'A-F' 'a-f')" ]; }
    ULN='(uint64,uint8,uint8,uint8,address[],address[])'
    uln() { cast abi-decode --input "x($ULN)" "$(c "$1" $EP 'getConfig(address,address,uint32,uint32)(bytes)' "$2" "$3" "$4" 2)" | tr '\n' ' '; }
    for side in "Ethereum $MAINNET_RPC_URL $SOBTC_ETHEREUM_RECORD $ETH_SAFE 30184 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1 0xc02Ab410f0734EFa3F14628780e6e695156024C2" \
                "Base $BASE_RPC_URL $SOBTC_BASE_RECORD $BASE_SAFE 30101 0xB5320B0B3a13cC860893E2Bd79FCd7e13484Dda2 0xc70AB6f32772f59fBfc23889Caf4Ba3376C84bAf"; do
      read -r n R F SAFE PEID SL RL <<< "$side"
      [ -f "$F" ] || { echo "=== $n: not deployed ($F missing)"; continue; }
      AUTH=$(rec "$F" RolesAuthority); VAULT=$(rec "$F" BoringVault); ACC=$(rec "$F" Accountant); TELLER=$(rec "$F" LayerZeroTeller)
      MGR=$(rec "$F" Manager); ASSET=$(rec "$F" asset)
      QUEUE=$(rec "$F" BoringQueue 2>/dev/null || true); SOLVER=$(rec "$F" BoringSolver 2>/dev/null || true); SS=$(rec "$F" SolverSafe 2>/dev/null || true)
      OWNED="AUTH VAULT ACC TELLER MGR"; [ -n "$QUEUE" ] && OWNED="$OWNED QUEUE SOLVER"
      echo "=== $n soBTC ($F)"
      echo "strategist manage root $(c $R $MGR 'manageRoot(address)(bytes32)' 0x6f3334EC6355eD6f70100Cd1Cd6736505cd0F9b5)"
      for x in $OWNED; do a=${!x}; o=$(c $R $a 'owner()(address)'); echo "$x $a owner $(same "$o" "$SAFE" && echo Safe || (same "$o" $DEPLOYER && echo 'deployer (handover pending)' || echo "WRONG $o"))"; done
      echo "vault $(c $R $VAULT 'symbol()(string)') $(c $R $VAULT 'decimals()(uint8)') dec, supply $(c $R $VAULT 'totalSupply()(uint256)'), $(c $R $ASSET 'symbol()(string)') held $(c $R $ASSET 'balanceOf(address)(uint256)' $VAULT)"
      echo "accountant rate $(c $R $ACC 'getRate()(uint256)') base $(c $R $ACC 'base()(address)')"
      echo "teller asset $(c $R $TELLER 'assetData(address)(bool,bool,uint16)' $ASSET | tr '\n' ' ')delegate $(c $R $EP 'delegates(address)(address)' $TELLER)"
      echo "-> $PEID: chain $(c $R $TELLER 'idToChains(uint32)(bool,bool,uint128)' $PEID | tr '\n' ' ')peer $(c $R $TELLER 'peers(uint32)(bytes32)' $PEID)"
      echo "   send $(uln $R $TELLER $SL $PEID)"
      echo "   recv $(uln $R $TELLER $RL $PEID)"
      if [ -n "$QUEUE" ]; then
        echo "queue $(c $R $QUEUE 'withdrawAssets(address)(bool,uint24,uint24,uint16,uint16,uint96,uint256)' $ASSET | head -6 | tr '\n' ' ')"
        echo "solver Safe $SS threshold $(c $R $SS 'getThreshold()(uint256)') owners $(c $R $SS 'getOwners()(address[])')"
      else
        echo "no queue: withdrawals are Ethereum-only"
      fi
      if [ "$n" = Ethereum ]; then W=$(cast abi-encode 'f(uint32)' 30184); else W=$(cast abi-encode 'f(uint32)' 30101); fi
      echo "bridge fee for 1 share: $(c $R $TELLER 'previewFee(uint96,address,bytes,address)(uint256)' 1 $SAFE $W $NATIVE) wei"
    done
    ;;

  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
