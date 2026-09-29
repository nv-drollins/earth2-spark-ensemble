#!/usr/bin/env bash
# Plain-English question -> validated plan -> REAL ensemble on the cluster.
#
#   ./agent/run-plan.sh "how much can we trust next week on the US east coast?"
#   ./agent/run-plan.sh --dry-run "zoom into rain bands over Taiwan"
#
# The agent only ever PROPOSES. agent/plan.py clamps every field against hard
# limits, and this script executes the clamped plan through the same
# scripts/ensemble.sh the manual path uses -- the model never touches the
# cluster directly.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$REPO/scripts/common.sh"

DRY=0
[[ "${1:-}" == "--dry-run" ]] && { DRY=1; shift; }
Q="${*:-}"
[[ -z "$Q" ]] && { echo "usage: $0 [--dry-run] \"your question\""; exit 1; }

SBX="${E2_SANDBOX:-e2-agent}"
NODE="${E2_AGENT_NODE:-}"
if [[ -z "$NODE" ]]; then
  for n in "${NODE_ARR[@]}"; do
    on_node "$n" "command -v nemoclaw >/dev/null" 2>/dev/null && { NODE="$n"; break; }
  done
fi
[[ -z "$NODE" ]] && { err "no node with nemoclaw -- run ./agent/setup-agent.sh"; exit 1; }

VIP=$(on_node "$NODE" "docker inspect ${E2_VLLM_CONTAINER:-vllm-server} --format '{{range \$k,\$v := .NetworkSettings.Networks}}{{if eq \$k \"openshell-docker\"}}{{\$v.IPAddress}}{{end}}{{end}}'" 2>/dev/null | tr -d '\r')
[[ -z "$VIP" ]] && { err "vLLM not on the openshell bridge -- run ./agent/setup-agent.sh"; exit 1; }

hdr "Question"
echo "  $Q"

# --- 1. propose (inside the sandbox) -------------------------------------
PB64=$(base64 -w0 < "$HERE/plan.py")
on_node "$NODE" "openshell sandbox exec --name '$SBX' --no-tty --timeout 30 -- \
  python3 -c 'import base64,sys,pathlib; pathlib.Path(\"/tmp/plan.py\").write_text(base64.b64decode(sys.argv[1]).decode())' '$PB64'" >/dev/null 2>&1

QB64=$(printf '%s' "$Q" | base64 -w0)
PLAN=$(on_node "$NODE" "openshell sandbox exec --name '$SBX' --no-tty --timeout 200 -- \
  python3 -c 'import base64,sys,subprocess,os; os.environ[\"E2_VLLM_IP\"]=\"$VIP\"; q=base64.b64decode(sys.argv[1]).decode(); sys.exit(subprocess.run([\"python3\",\"/tmp/plan.py\",q],env=os.environ).returncode)' '$QB64'" 2>/dev/null)

if ! python3 -c "import json,sys; json.loads(sys.stdin.read())" <<< "$PLAN" 2>/dev/null; then
  err "planner did not return JSON:"; sed 's/^/    /' <<< "$(head -c 400 <<< "$PLAN")"; exit 1
fi

read -r MEMBERS STEPS NOISE REGION VARIABLE DOWNSCALE EST INTENT <<< "$(
  python3 - "$PLAN" <<'PY'
import json, sys
p = json.loads(sys.argv[1])
print(p["members"], p["steps"], p["noise"], p["region"], p["variable"],
      int(bool(p["downscale"])), p["estimate_s"], p.get("intent", "").replace("\n", " "))
PY
)"

hdr "Plan"
printf '  %-12s %s\n' "intent"    "$INTENT"
printf '  %-12s %s members\n'     "ensemble" "$MEMBERS"
printf '  %-12s %s x 6h = %s hours\n' "horizon" "$STEPS" "$((STEPS*6))"
printf '  %-12s %s\n' "perturbation" "$NOISE"
printf '  %-12s %s\n' "region"    "$REGION"
printf '  %-12s %s\n' "variable"  "$VARIABLE"
printf '  %-12s %s\n' "downscale" "$([[ $DOWNSCALE -eq 1 ]] && echo yes || echo no)"
printf '  %-12s ~%ss\n' "estimate" "$EST"

# Clamp notes are the audit trail -- always show them. They are how you see
# that the guard corrected the model rather than the model getting it right.
python3 - "$PLAN" <<'PY'
import json, sys
for n in json.loads(sys.argv[1]).get("notes", []):
    print(f"  \033[33madjusted\033[0m   {n}")
PY

if [[ $DRY -eq 1 ]]; then
  echo
  c_ylw "  dry run -- nothing executed."
  exit 0
fi

# --- 2. execute (the SAME path the manual demo uses) ---------------------
hdr "Running on the cluster"
DATE="${DATE:-$(date -u -d '2 days ago' +%Y-%m-%d)}"
MEMBERS="$MEMBERS" STEPS="$STEPS" NOISE="$NOISE" DATE="$DATE" \
  bash "$REPO/scripts/ensemble.sh" || { err "ensemble failed"; exit 1; }

bash "$REPO/scripts/collect.sh" >/dev/null 2>&1 || warn "collect reported an issue"

if [[ $DOWNSCALE -eq 1 ]]; then
  hdr "Downscaling (CorrDiff)"
  bash "$REPO/scripts/corrdiff.sh" --date "$DATE" || warn "downscale failed"
fi

hdr "Rendering"
python3 "$REPO/viz/render.py" >/dev/null 2>&1 && ok "frames rendered" || warn "render issue"
c_grn "Done -- the display is showing the new run."
