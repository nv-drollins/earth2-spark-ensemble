#!/usr/bin/env bash
# Ask the sandboxed Earth-2 booth agent a question.
#
#   ./agent/ask.sh "why are six forecasts better than one?"
#
# The agent runs inside the NemoClaw sandbox with Hermes as its runtime and can
# reach ONLY the vLLM inference endpoints -- see docs/AGENT.md.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$REPO/scripts/common.sh"

SBX="${E2_SANDBOX:-e2-agent}"
Q="${*:-}"
[[ -z "$Q" ]] && { echo "usage: $0 \"your question\""; exit 1; }

NODE="${E2_AGENT_NODE:-}"
if [[ -z "$NODE" ]]; then
  for n in "${NODE_ARR[@]}"; do
    if on_node "$n" "command -v nemoclaw >/dev/null" 2>/dev/null; then NODE="$n"; break; fi
  done
fi
[[ -z "$NODE" ]] && { err "no node with nemoclaw -- run ./agent/setup-agent.sh"; exit 1; }

# The vLLM container's address on the openshell bridge can change when it is
# recreated, so resolve it each  run rather than baking it into ask.py.
VIP=$(on_node "$NODE" "docker inspect ${E2_VLLM_CONTAINER:-e2-llm} --format '{{range \$k,\$v := .NetworkSettings.Networks}}{{if eq \$k \"openshell-docker\"}}{{\$v.IPAddress}}{{end}}{{end}}'" 2>/dev/null | tr -d '\r')
[[ -z "$VIP" ]] && { err "vLLM not on the openshell bridge -- run ./agent/setup-agent.sh"; exit 1; }

# The sandbox is isolated and CANNOT read the workstation's render manifest,
# so resolve the current run's numbers HERE and pass them in. Without this the
# agent falls back to describing the shape of the result and refuses to quote
# figures -- or worse, recites stale hardcoded ones that contradict the screen.
FACTS_B64=$(python3 - <<'PY' 2>/dev/null || echo ""
import base64, json, os, sys
path = os.environ.get("E2_MANIFEST", os.path.expanduser("~/e2viz/frames/manifest.json"))
try:
    m = json.load(open(path))
    c = m["curve"]
    first, last = c[0], c[-1]
    out = ["CURRENT RUN (these are the numbers on the display right now):",
           f"  {len(m.get('members', []))} ensemble members.",
           f"  Forecast horizon {last['lead_h']} hours ({len(c)-1} steps of 6 hours).",
           f"  Ensemble spread in 2m temperature: {first['mean_K']} K at hour 0, "
           f"rising to {last['mean_K']} K at {last['lead_h']} h "
           f"(maximum {last['max_K']} K in the most volatile regions)."]
    for r in c:
        if r["lead_h"] in (24, 48):
            out.append(f"  At {r['lead_h']} h the mean spread is {r['mean_K']} K.")
    cd = m.get("corrdiff") or {}
    if cd.get("resolution_gain"):
        out.append(f"  CorrDiff downscaling gain this run: {cd['resolution_gain']}x.")
    print(base64.b64encode("\n".join(out).encode()).decode())
except Exception:
    print("")
PY
)

# Seed the asker into the sandbox (cheap; keeps it in sync with the repo copy).
B64=$(base64 -w0 < "$HERE/ask.py")
on_node "$NODE" "openshell sandbox exec --name '$SBX' --no-tty --timeout 30 -- \
  python3 -c 'import base64,sys,pathlib; pathlib.Path(\"/tmp/ask.py\").write_text(base64.b64decode(sys.argv[1]).decode())' '$B64'" >/dev/null 2>&1

# Pass the QUESTION as base64 too: plain argv gets shredded by the
# ssh -> bash -lc -> openshell exec quoting layers and the model then replies
# that the question is "incomplete".
QB64=$(printf '%s' "$Q" | base64 -w0)
on_node "$NODE" "openshell sandbox exec --name '$SBX' --no-tty --timeout 200 -- \
  python3 -c 'import base64,sys,subprocess,os; q=base64.b64decode(sys.argv[1]).decode(); os.environ[\"E2_VLLM_IP\"]=\"$VIP\"; os.environ[\"E2_LIVE_FACTS_B64\"]=sys.argv[2]; sys.exit(subprocess.run([\"python3\",\"/tmp/ask.py\",q], env={**os.environ}).returncode)' '$QB64' '$FACTS_B64'"
