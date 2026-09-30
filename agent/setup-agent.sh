#!/usr/bin/env bash
# Provision the NemoClaw sandbox that runs the Earth-2 agent.
#
# The agent runs INSIDE a NemoClaw/OpenShell sandbox (Debian 13, non-root, no
# sudo, deny-by-default egress) with Hermes Agent as the runtime. It reaches an
# existing vLLM on the same host through an explicitly approved policy preset --
# nothing else. That containment is itself part of the booth story.
#
# Prereqs on the target node: an already-running vLLM, and NemoClaw installed:
#   curl -fsSL https://www.nvidia.com/nemoclaw.sh | \
#     NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 NEMOCLAW_SANDBOX_NAME=throwaway-init bash
# (Give that installer a THROWAWAY sandbox name: its auto-onboard otherwise
# creates a sandbox with different flags than the ones this script makes.)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$REPO/scripts/common.sh"

SBX="${E2_SANDBOX:-e2-agent}"
VLLM_CONTAINER="${E2_VLLM_CONTAINER:-e2-llm}"
VLLM_PORT="${E2_VLLM_PORT:-8000}"
MODEL="${E2_AGENT_MODEL:-}"

# The agent belongs on whichever node actually SERVES the model -- which is not
# necessarily NODE_ARR[0]. Auto-detect by probing each node for a live vLLM,
# unless the operator pins one explicitly.
NODE="${E2_AGENT_NODE:-}"
if [[ -z "$NODE" ]]; then
  for n in "${NODE_ARR[@]}"; do
    if on_node "$n" "curl -s -o /dev/null --max-time 5 http://127.0.0.1:$VLLM_PORT/v1/models" 2>/dev/null; then
      NODE="$n"; break
    fi
  done
fi
if [[ -z "$NODE" ]]; then
  err "no node in NODES is serving a model on port $VLLM_PORT."
  echo "  Start one, or pin the node with:  E2_AGENT_NODE=user@host ./agent/setup-agent.sh"
  exit 1
fi

hdr "Earth-2 agent sandbox on $NODE"

# 0. NemoClaw present? Its installer AUTO-RUNS `nemoclaw onboard`, which tries
#    to stand up its OWN vLLM on :8000 and aborts when one is already there:
#      "vLLM install failed: port 8000 is already in use by another process."
#    That abort is EXPECTED and harmless -- the CLIs still install fine, and
#    this script then onboards against the existing model. Say so up front so
#    nobody tries to "fix" a working install.
if ! on_node "$NODE" "command -v nemoclaw >/dev/null"; then
  err "nemoclaw not found on $NODE."
  echo "  Install it (run ON that node):"
  echo "    curl -fsSL https://www.nvidia.com/nemoclaw.sh | \\"
  echo "      NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 NEMOCLAW_SANDBOX_NAME=throwaway-init bash"
  echo
  echo "  NOTE: it will END with 'vLLM install failed: port 8000 is already in"
  echo "  use' and exit non-zero. That is FINE -- the CLIs installed; this"
  echo "  script handles the onboarding. Verify with: nemoclaw --version"
  echo "  Then clean up its throwaway sandbox: nemoclaw throwaway-init destroy --yes"
  exit 1
fi
ok "nemoclaw $(on_node "$NODE" "nemoclaw --version 2>/dev/null | head -1" | tr -d '\r')"

# 1. The vLLM container must share the openshell bridge, or the sandbox cannot
#    route to it at all.
on_node "$NODE" "docker network connect openshell-docker '$VLLM_CONTAINER' 2>/dev/null" || true
VIP=$(on_node "$NODE" "docker inspect '$VLLM_CONTAINER' --format '{{range \$k,\$v := .NetworkSettings.Networks}}{{if eq \$k \"openshell-docker\"}}{{\$v.IPAddress}}{{end}}{{end}}'" 2>/dev/null | tr -d '\r')
[[ -z "$VIP" ]] && { err "could not find $VLLM_CONTAINER on the openshell-docker network"; exit 1; }
ok "vLLM reachable at $VIP:$VLLM_PORT on the openshell bridge"

# vLLM must bind 0.0.0.0 INSIDE the container; the default 127.0.0.1 makes every
# bridge address refuse even though `ss` on the host shows 0.0.0.0.
if [[ -z "$MODEL" ]]; then
  MODEL=$(on_node "$NODE" "curl -s --max-time 8 http://127.0.0.1:$VLLM_PORT/v1/models" \
          | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null)
fi
[[ -z "$MODEL" ]] && { err "no model served on $NODE:$VLLM_PORT"; exit 1; }
ok "model: $MODEL"

# 2. Onboard the sandbox with Hermes as the agent runtime, pointed at the
#    EXISTING vLLM (--no-gpu keeps it from downloading a second model).
if on_node "$NODE" "openshell sandbox list 2>/dev/null | grep -q '^$SBX '"; then
  ok "sandbox '$SBX' already exists -- skipping onboard"
else
  echo "  onboarding '$SBX' (~60s)..."
  on_node "$NODE" "export NEMOCLAW_PROVIDER=custom \
      NEMOCLAW_ENDPOINT_URL=http://host.openshell.internal:$VLLM_PORT/v1 \
      NEMOCLAW_MODEL='$MODEL' COMPATIBLE_API_KEY=dummy NEMOCLAW_YES=1 \
      NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 NEMOCLAW_AGENT=hermes \
      NEMOCLAW_PREFERRED_API=openai-completions; \
    nemoclaw onboard --non-interactive --yes --yes-i-accept-third-party-software \
      --agent hermes --name '$SBX' --no-gpu --no-sandbox-gpu" >/dev/null 2>&1 \
    && ok "sandbox onboarded" || { err "onboard failed"; exit 1; }
fi

# 3. Apply the scoped egress policy. Deny-by-default is the whole point: without
#    this the sandbox gets 403 policy_denied on every inference call.
sed "s/host: .*/host: $VIP/" "$HERE/e2-vllm-policy.yaml" > /tmp/e2-vllm-rendered.yaml
scp -o BatchMode=yes -q /tmp/e2-vllm-rendered.yaml "$NODE:/tmp/e2-vllm.yaml"
on_node "$NODE" "nemoclaw '$SBX' policy-add local-inference --yes" >/dev/null 2>&1 || true
on_node "$NODE" "nemoclaw '$SBX' policy-add --from-file /tmp/e2-vllm.yaml --trusted-private-host '$VIP' --yes" >/dev/null 2>&1 \
  && ok "egress policy applied (inference endpoints only)" || warn "policy-add reported an issue"

# 4. Prove it end to end -- a sandbox that cannot reach the model is useless.
hdr "Verification"
RESP=$(on_node "$NODE" "openshell sandbox exec --name '$SBX' --no-tty --timeout 30 -- bash -lc \"curl -s --max-time 15 http://$VIP:$VLLM_PORT/v1/models\"" 2>/dev/null)
if grep -q '"object"' <<< "$RESP"; then
  ok "sandbox reaches the model"
else
  err "sandbox cannot reach the model:"; sed 's/^/       /' <<< "$(head -c 300 <<< "$RESP")"; exit 1
fi
c_grn "Agent sandbox '$SBX' ready on $NODE."
