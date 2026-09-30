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

# Seed the asker into the sandbox (cheap; keeps it in sync with the repo copy).
B64=$(base64 -w0 < "$HERE/ask.py")
on_node "$NODE" "openshell sandbox exec --name '$SBX' --no-tty --timeout 30 -- \
  python3 -c 'import base64,sys,pathlib; pathlib.Path(\"/tmp/ask.py\").write_text(base64.b64decode(sys.argv[1]).decode())' '$B64'" >/dev/null 2>&1

# Pass the QUESTION as base64 too: plain argv gets shredded by the
# ssh -> bash -lc -> openshell exec quoting layers and the model then replies
# that the question is "incomplete".
QB64=$(printf '%s' "$Q" | base64 -w0)
on_node "$NODE" "E2_VLLM_IP='$VIP' openshell sandbox exec --name '$SBX' --no-tty --timeout 200 -- \
  python3 -c 'import base64,sys,subprocess,os; q=base64.b64decode(sys.argv[1]).decode(); os.environ[\"E2_VLLM_IP\"]=\"$VIP\"; sys.exit(subprocess.run([\"python3\",\"/tmp/ask.py\",q], env={**os.environ}).returncode)' '$QB64'"
