#!/usr/bin/env bash
# Deploys and configures one vault on Base (VAULT_SYMBOL, soEUR when unset) for one environment, qa or
# prod: deploy, configure, verify. Each vault and environment has its own record file (see
# deployment.js), so a QA run can never touch PROD and one vault's run never touches another's.
# Stops at the first error; rerunning skips every step already done. A record with a superVault (the
# stock vaults) also gets its strategy: a decoder and the strategist's manage root. It never hands
# over ownership: once the checks pass, run
#   VAULT_SYMBOL=<vault> DEPLOYMENT=<qa|prod> npx hardhat run scripts/MVP/config/transferOwnership.js --network base
#
# Usage, from the repo root:
#   bash scripts/MVP/deploy-base.sh qa                           deploy and configure soEUR QA
#   VAULT_SYMBOL=soNVDA bash scripts/MVP/deploy-base.sh prod            deploy and configure soNVDA PROD
#   VAULT_SYMBOL=soNVDA bash scripts/MVP/deploy-base.sh prod --check    read-only checks; sends nothing
# Needs PRIVATE_KEY (the record's deployer key) in .env. BASE_RPC_URL comes from .env if set, else
# the public https://mainnet.base.org.
set -euo pipefail

ENV=${1:-}; MODE=${2:-}
case "$ENV" in qa|prod) ;; *) echo "Usage: bash scripts/MVP/deploy-base.sh qa|prod [--check]" >&2; exit 1 ;; esac
[ -z "$MODE" ] || [ "$MODE" = "--check" ] || { echo "Unknown option: $MODE" >&2; exit 1; }
export DEPLOYMENT=$ENV

REPO=$(cd "$(dirname "$0")/../.." && pwd)
MVP=$REPO/scripts/MVP
LOG=${LOG:-$REPO/deploy-base-${VAULT_SYMBOL:+$VAULT_SYMBOL-}$ENV.log}
cd "$REPO"
STATE=$(node -e "console.log(require('./scripts/MVP/deployment').load().file)")

if [ -z "${BASE_RPC_URL:-}" ]; then
  BASE_RPC_URL=$(grep -E '^BASE_RPC_URL=.+' .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d "\"'" || true)
fi
export BASE_RPC_URL=${BASE_RPC_URL:-https://mainnet.base.org}
RPC=$BASE_RPC_URL

die() { echo; echo "STOPPED: $*" >&2; exit 1; }
c() { cast call -r "$RPC" "$@" 2>/dev/null; }

# Record file: settings (config), deployed addresses (contracts) and finished steps (done).
rec() { python3 -I - "$STATE" "$@" <<'EOF'
import json, sys
path, op, *args = sys.argv[1:]
d = json.load(open(path))
if op == "contract":
    print(d["contracts"].get(args[0], ""))
elif op == "config":
    v = d["config"].get(args[0])
    print(" ".join(v) if isinstance(v, list) else ("" if v is None else v))
elif op == "safe":
    s = d["config"].get("ownerSafe")
    print("" if not s else f'{s["threshold"]} {" ".join(sorted(o.lower() for o in s["owners"]))}')
elif op == "isdone":
    print("yes" if args[0] in d["done"] else "")
elif op == "done":
    if args[0] not in d["done"]:
        d["done"].append(args[0])
    with open(path, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
EOF
}

NC=""  # compile on the first script only
run() {  # run one hardhat script; output goes to the screen and the log
  echo; echo ">>> $1"
  npx hardhat run "$MVP/$1" --network base $NC 2>&1 | grep -v deny_warnings | tee -a "$LOG"
  local rc=${PIPESTATUS[0]}
  NC=--no-compile
  return "$rc"
}

# ── Preflight ───────────────────────────────────────────────────────────────
DEPLOYER=$(rec config deployer); OWNER=$(rec config owner)
SYMBOL=$(rec config vaultTokenSymbol); BASE=$(rec config baseAsset); SUPERVAULT=$(rec config superVault)
[ -n "$BASE" ] || die "no baseAsset in $STATE"
CHAIN=$(cast chain-id -r "$RPC" 2>/dev/null || true)
[ "$CHAIN" = "8453" ] || die "the RPC is not Base (chain id '${CHAIN}', expected 8453)"
echo "Vault:       $SYMBOL (base asset $(c $BASE 'symbol()(string)') $BASE)"
echo "Environment: $ENV"
echo "Network:     Base (8453)"
echo "Record:      $STATE"
echo "Deployer:    $DEPLOYER  balance $(cast balance $DEPLOYER -e -r "$RPC" 2>/dev/null) ETH"
echo "Final owner: $OWNER"

if [ "$MODE" != "--check" ]; then
  echo "Log:         $LOG"
  if [ "${YES:-}" != "1" ]; then
    read -r -p "This sends real transactions on Base for $SYMBOL $ENV. Type '$ENV' to continue: " answer
    [ "$answer" = "$ENV" ] || die "not confirmed"
  fi
  echo "=== $SYMBOL $ENV run $(date -u +%FT%TZ) ===" >> "$LOG"

  # ── 1. Core contracts ─────────────────────────────────────────────────────
  if [ -z "$(rec isdone deployAll)" ]; then
    [ -z "$(rec isdone deployAllStarted)" ] || die "deployAll.js started earlier but did not finish. Do not rerun it: the contracts it deployed are in $STATE. Ask for help."
    rec done deployAllStarted
    run deployAll.js || die "deployAll.js failed partway. The contracts it deployed are in $STATE. Do not rerun this script; ask for help."
    rec done deployAll
  fi

  # ── 2–3. Queue and solver ─────────────────────────────────────────────────
  [ -n "$(rec contract BoringQueue)" ] || run 05_deployBoringQueue.js || die "05_deployBoringQueue.js failed"
  [ -n "$(rec contract BoringSolver)" ] || run 06_deployBoringSolver.js || die "06_deployBoringSolver.js failed"

  # ── 4–9. Configure, then repair any missing authority ─────────────────────
  for s in setRolesConfig setSolverRoles setQueuePublicCapabilities setBeforeTransferHook configureTeller setWithdrawAsset setAuthorities; do
    if [ -z "$(rec isdone $s)" ]; then
      run "config/$s.js" || die "config/$s.js failed. Rerunning this script resumes from it."
      rec done "$s"
    fi
  done

  # ── 10–11. Strategy: decoder and the strategist's manage root (stock vaults) ─
  if [ -n "$SUPERVAULT" ]; then
    [ -n "$(rec contract Decoder)" ] || run 07_deployDecoder.js || die "07_deployDecoder.js failed"
    if [ -z "$(rec isdone setManageRoot)" ]; then
      run config/setManageRoot.js || die "config/setManageRoot.js failed. Rerunning this script resumes from it."
      rec done setManageRoot
    fi
  fi
fi

# ── Verify (read-only) ──────────────────────────────────────────────────────
AUTH=$(rec contract RolesAuthority); VAULT=$(rec contract BoringVault); ACC=$(rec contract Accountant)
TELLER=$(rec contract Teller); MGR=$(rec contract Manager); QUEUE=$(rec contract BoringQueue); SOLVER=$(rec contract BoringSolver)
for x in AUTH VAULT ACC TELLER MGR QUEUE SOLVER; do [ -n "${!x}" ] || die "$ENV is not fully deployed yet (no $x in $STATE)"; done
STRATEGIST=$(rec config strategist); UPDATER=$(rec config rateUpdater); OPERATOR=$(rec config solverOperator)
PAYOUT=$(rec config payoutAddress); FORMER=$(rec config formerSolverOperators)
role() { c $AUTH 'doesUserHaveRole(address,uint8)(bool)' $1 $2; }
pub() { c $AUTH 'isCapabilityPublic(address,bytes4)(bool)' $1 $2; }
same() { [ "$(echo "$1" | tr 'A-F' 'a-f')" = "$(echo "$2" | tr 'A-F' 'a-f')" ]; }

echo; echo "=== Checks on Base ($ENV) ==="
for x in VAULT ACC TELLER MGR QUEUE SOLVER; do a=${!x}; echo "$x $a authority $( same "$(c $a 'authority()(address)')" "$AUTH" && echo ok || echo WRONG)"; done
echo "vault: $(c $VAULT 'name()(string)') $(c $VAULT 'symbol()(string)') $(c $VAULT 'decimals()(uint8)') decimals, hook $( same "$(c $VAULT 'hook()(address)')" "$TELLER" && echo ok || echo WRONG)"
echo "accountant rate: $(c $ACC 'getRate()(uint256)')  base: $(c $ACC 'base()(address)')"
echo "public deposit=$(pub $TELLER 0x0efe6a8b) requestWithdraw=$(pub $QUEUE 0x6bb3b476) withPermit=$(pub $QUEUE 0x581b4920) cancel=$(pub $QUEUE 0x4a2dc5e4) cancelById=$(pub $QUEUE 0x08bf866e) replace=$(pub $QUEUE 0xa5672fd7)  teller enter=$(c $AUTH 'canCall(address,address,bytes4)(bool)' $TELLER $VAULT 0x39d6ba32) exit=$(c $AUTH 'canCall(address,address,bytes4)(bool)' $TELLER $VAULT 0x18457e61)"
echo "base asset $(c $BASE 'symbol()(string)'): $(c $TELLER 'assetData(address)(bool,bool,uint16)' $BASE | tr '\n' ' ')"
echo "strategist $STRATEGIST: strategies $(role $STRATEGIST 7)$(same $STRATEGIST $UPDATER || echo ", rate updates $(role $STRATEGIST 11) (want false)")"
echo "rate updater $UPDATER: rate updates $(role $UPDATER 11)"
if [ -n "$SUPERVAULT" ]; then
  DECODER=$(rec contract Decoder)
  TREE=$(node -e "console.log(require('./scripts/MVP/strategy/leafs').treeFilePath(require('./scripts/MVP/deployment').load()))")
  WANT=$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["metadata"]["ManageRoot"])' "$TREE" 2>/dev/null || true)
  GOT=$(c $MGR 'manageRoot(address)(bytes32)' $STRATEGIST)
  echo "strategy: SuperVault $SUPERVAULT ($(c $SUPERVAULT 'symbol()(string)')), decoder ${DECODER:-MISSING}, manage root $( [ -n "$WANT" ] && [ "$GOT" = "$WANT" ] && echo "$GOT matches $(basename "$TREE")" || echo "$GOT DOES NOT MATCH ${TREE}")"
fi
echo "solver operator $OPERATOR: can process withdrawals $(c $AUTH 'canCall(address,address,bytes4)(bool)' $OPERATOR $SOLVER 0x5ff8a71f)"
for f in $FORMER; do echo "former solver operator $f: can process withdrawals $(c $AUTH 'canCall(address,address,bytes4)(bool)' $f $SOLVER 0x5ff8a71f) (want false)"; done
echo "fee recipient: $( same "$(c $ACC 'accountantState()(address,uint96,uint128,uint128,uint96,uint16,uint16,uint64,bool,uint24,uint16,uint16)' | head -1)" "$PAYOUT" && echo "$PAYOUT ok" || echo WRONG)"
pending=no
for x in AUTH VAULT ACC TELLER MGR QUEUE SOLVER; do
  o=$(c ${!x} 'owner()(address)')
  if same "$o" "$OWNER"; then s="final owner"; elif same "$o" "$DEPLOYER"; then s="deployer (handoff pending)"; pending=yes; else s="UNEXPECTED $o"; fi
  echo "$x owner: $s"
done
SAFE=$(rec safe)
if [ -n "$SAFE" ]; then
  got="$(c $OWNER 'getThreshold()(uint256)') $(c $OWNER 'getOwners()(address[])' | tr -d '[],' | tr 'A-F' 'a-f' | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
  echo "owner Safe $OWNER: $( [ "$got" = "$SAFE" ] && echo "signers match the record" || echo "signers DO NOT match the record: $got")"
fi

echo
echo "Done. Addresses are in $STATE."
if [ "$pending" = yes ]; then
  echo "Next: hand ownership to $OWNER:"
  echo "  ${VAULT_SYMBOL:+VAULT_SYMBOL=$VAULT_SYMBOL }DEPLOYMENT=$ENV npx hardhat run scripts/MVP/config/transferOwnership.js --network base"
fi
