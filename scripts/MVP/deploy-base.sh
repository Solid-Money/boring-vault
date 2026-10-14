#!/usr/bin/env bash
# Deploys and configures soEURC on Base in one go: deploy, configure, recreate the soETH Safes on
# Base, verify. Stops at the first error; rerunning skips every step already done (recorded in
# $STATE). It never hands over ownership: once the Safe signers are fixed in Safe{Wallet}, run
#   npx hardhat run scripts/MVP/config/transferOwnership.js --network base
#
# Usage, from the repo root:  bash scripts/MVP/deploy-base.sh
# Needs PRIVATE_KEY (the 0x607B…4628 key) in .env. BASE_RPC_URL comes from .env if set, else the
# public https://mainnet.base.org.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
MVP=${MVP_DIR:-$REPO/scripts/MVP}
STATE=${STATE:-$REPO/deployments/addresses/Base/soEURC.json}
LOG=${LOG:-$REPO/deploy-base.log}
DEPLOYER=0x607B5576B3C5a748C1Fe9d155a94f322E15F4628
EURC=0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42
cd "$REPO"

if [ -z "${BASE_RPC_URL:-}" ]; then
  BASE_RPC_URL=$(grep -E '^BASE_RPC_URL=.+' .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d "\"'" || true)
fi
export BASE_RPC_URL=${BASE_RPC_URL:-https://mainnet.base.org}
RPC=$BASE_RPC_URL

die() { echo; echo "STOPPED: $*" >&2; exit 1; }
c() { cast call -r "$RPC" "$@" 2>/dev/null; }

# State file: deployed addresses and finished steps.
st() { python3 -I - "$STATE" "$@" <<'EOF'
import json, os, sys
path, op, *args = sys.argv[1:]
d = json.load(open(path)) if os.path.exists(path) else {"network": "base", "chainId": 8453, "contracts": {}, "done": []}
if op == "get":
    print(d["contracts"].get(args[0], ""))
elif op == "isdone":
    print("yes" if args[0] in d["done"] else "")
else:
    if op == "set":
        d["contracts"][args[0]] = args[1]
    elif op == "done" and args[0] not in d["done"]:
        d["done"].append(args[0])
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
EOF
}

# Replace the scripts' '' // TODO(Base) placeholders with addresses from the state file.
fill() { python3 -I - "$MVP" "$STATE" <<'EOF'
import json, re, pathlib, sys
mvp, state = sys.argv[1:]
c = json.load(open(state))["contracts"]
m = {'authorityAddress': 'RolesAuthority', 'boringVault': 'BoringVault', 'boringVaultAddress': 'BoringVault',
     'vaultAddress': 'BoringVault', 'accountant': 'Accountant', 'accountantAddress': 'Accountant',
     'tellerAddress': 'Teller', 'managerAddress': 'Manager', 'boringQueueWithTrackingAddress': 'BoringQueue',
     'boringQueueAddress': 'BoringQueue', 'boringSolverAddress': 'BoringSolver'}
def sub(x):
    addr = c.get(m.get(x.group(2), ''))
    return f"{x.group(1)}'{addr}' // Base{x.group(3)}" if addr else x.group(0)
for p in pathlib.Path(mvp).rglob('*.js'):
    s = p.read_text()
    n = re.sub(r"^(const (\w+) = )'' // TODO\(Base\)(.*)$", sub, s, flags=re.M)
    if n != s:
        p.write_text(n)
EOF
}

OUT=$(mktemp)
NC=""  # compile on the first script only
run() {  # run one hardhat script; output goes to the screen, the log and $OUT
  echo; echo ">>> $1"
  npx hardhat run "$MVP/$1" --network base $NC 2>&1 | grep -v deny_warnings | tee "$OUT" | tee -a "$LOG"
  local rc=${PIPESTATUS[0]}
  NC=--no-compile
  return "$rc"
}
grab() { grep -E "$1" "$OUT" | grep -oE '0x[0-9a-fA-F]{40}' | tail -1; }
unfilled() { grep -l "'' // TODO(Base)" "$@" 2>/dev/null || true; }

# ── Preflight ───────────────────────────────────────────────────────────────
CHAIN=$(cast chain-id -r "$RPC" 2>/dev/null || true)
[ "$CHAIN" = "8453" ] || die "the RPC is not Base (chain id '${CHAIN}', expected 8453)"
echo "Network:  Base (8453)"
echo "Deployer: $DEPLOYER  balance $(cast balance $DEPLOYER -e -r "$RPC" 2>/dev/null) ETH"
echo "State:    $STATE"
echo "Log:      $LOG"
if [ "${YES:-}" != "1" ]; then
  read -r -p "This sends real transactions on Base. Type 'deploy' to continue: " answer
  [ "$answer" = "deploy" ] || die "not confirmed"
fi
echo "=== soEURC Base run $(date -u +%FT%TZ) ===" >> "$LOG"

# ── 1. Core contracts ───────────────────────────────────────────────────────
if [ -z "$(st get BoringVault)" ]; then
  [ -z "$(st isdone deployAllStarted)" ] || die "deployAll.js started earlier but did not finish. Do not rerun it: some contracts may already exist. Check $LOG and $STATE."
  st done deployAllStarted
  ok=yes; run deployAll.js || ok=no
  for pair in "RolesAuthority:RolesAuthority deployed at" "BoringVault:Vault deployed at" "Accountant:Accountant deployed at" \
              "Teller:Teller deployed at" "Manager:Manager deployed at"; do
    a=$(grab "${pair#*:}"); [ -z "$a" ] || st set "${pair%%:*}" "$a"
  done
  [ "$ok" = yes ] || die "deployAll.js failed partway. Addresses deployed so far are in $STATE. Do not rerun this script; ask for help."
  for k in RolesAuthority BoringVault Accountant Teller Manager; do [ -n "$(st get $k)" ] || die "no $k address in the deployAll.js output"; done
  st done deployAll
fi
fill

# ── 2–3. Queue and solver ───────────────────────────────────────────────────
if [ -z "$(st get BoringQueue)" ]; then
  run 05_deployBoringQueue.js || die "05_deployBoringQueue.js failed"
  a=$(grab 'Queue With Tracking deployed'); [ -n "$a" ] || die "no queue address in the output"
  st set BoringQueue "$a"; fill
fi
if [ -z "$(st get BoringSolver)" ]; then
  run 06_deployBoringSolver.js || die "06_deployBoringSolver.js failed"
  a=$(grab 'Boring Solver deployed'); [ -n "$a" ] || die "no solver address in the output"
  st set BoringSolver "$a"; fill
fi

# ── 4–9. Configure, repair any missing authority, then recreate the Safes ───
STEPS="setRolesConfig setSolverRoles setQueuePublicCapabilities setBeforeTransferHook configureTeller setWithdrawAsset setAuthorities recreateSafes"
left=$(unfilled $(for s in $STEPS; do echo "$MVP/config/$s.js"; done))
[ -z "$left" ] || die "placeholders not filled in: $left"
for s in $STEPS; do
  if [ -z "$(st isdone $s)" ]; then
    run "config/$s.js" || die "config/$s.js failed. Rerunning this script resumes from it."
    st done "$s"
  fi
done

# ── Verify (read-only) ──────────────────────────────────────────────────────
AUTH=$(st get RolesAuthority); VAULT=$(st get BoringVault); ACC=$(st get Accountant); TELLER=$(st get Teller)
MGR=$(st get Manager); QUEUE=$(st get BoringQueue); SOLVER=$(st get BoringSolver)
echo; echo "=== Checks on Base ==="
for x in VAULT ACC TELLER MGR QUEUE SOLVER; do a=${!x}; echo "$x $a authority $( [ "$(c $a 'authority()(address)')" = "$AUTH" ] && echo ok || echo WRONG)"; done
echo "vault: $(c $VAULT 'name()(string)') $(c $VAULT 'symbol()(string)') $(c $VAULT 'decimals()(uint8)') decimals, hook $( [ "$(c $VAULT 'hook()(address)')" = "$TELLER" ] && echo ok || echo WRONG)"
echo "accountant rate: $(c $ACC 'getRate()(uint256)')  base: $(c $ACC 'base()(address)')"
pub() { c $AUTH 'isCapabilityPublic(address,bytes4)(bool)' $1 $2; }
echo "public deposit=$(pub $TELLER 0x0efe6a8b) requestWithdraw=$(pub $QUEUE 0x6bb3b476) cancelWithdraw=$(pub $QUEUE 0x08bf866e)  teller enter=$(c $AUTH 'canCall(address,address,bytes4)(bool)' $TELLER $VAULT 0x39d6ba32) exit=$(c $AUTH 'canCall(address,address,bytes4)(bool)' $TELLER $VAULT 0x18457e61)"
echo "EURC asset: $(c $TELLER 'assetData(address)(bool,bool,uint16)' $EURC | tr '\n' ' ')"
for x in AUTH VAULT ACC TELLER MGR QUEUE SOLVER; do a=${!x}; echo "$x owner $(c $a 'owner()(address)')"; done
for s in 0x6B26fAF3AD822695127B29ad242ac4B33D336F42 0xA7Fdc92eDa10eac8d6AfD3037d398929B57303D7; do
  echo "Safe $s: $(c $s 'getThreshold()(uint256)')-of-$(c $s 'getOwners()(address[])')"
done

echo
echo "Done. Addresses are in $STATE."
echo "Next: fix both Safes' signers in Safe{Wallet} on Base, then run"
echo "  npx hardhat run scripts/MVP/config/transferOwnership.js --network base"
