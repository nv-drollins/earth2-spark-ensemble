# Agentic Layer

The Earth-2 agent runs **inside a NemoClaw / OpenShell sandbox** with
**Hermes Agent** as the in-sandbox runtime. The containment is not incidental —
it is part of the booth story.

## Why sandbox the agent at all

An agent that plans and dispatches HPC jobs is exactly the thing a national-lab
visitor will be most suspicious of. The honest answer is that it runs in a box
it cannot escape:

| | |
|---|---|
| OS | Debian 13, **non-root** `sandbox` user, no sudo, no apt/pip |
| Filesystem | its own, isolated from the host and from other sandboxes |
| Egress | **deny by default** — every destination must be explicitly approved |
| Model access | one vLLM, **two endpoints only** (`/v1/models`, `/v1/chat/completions`) |

That last row is enforced, not promised. Remove the policy and the same call
returns `403 policy_denied`. It is a live, demonstrable boundary — and a good
beat in its own right if a visitor asks "what stops it doing something weird?"

## Setup

```bash
# On the agent node, once: install NemoClaw with a THROWAWAY sandbox name so its
# auto-onboard doesn't create a sandbox with different flags than ours.
curl -fsSL https://www.nvidia.com/nemoclaw.sh | \
  NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 NEMOCLAW_SANDBOX_NAME=throwaway-init bash

# From the workstation:
./agent/setup-agent.sh
```

Idempotent: re-running skips an existing sandbox and re-asserts the policy. It
auto-detects which node is serving a model (pin it with `E2_AGENT_NODE=user@host`).

### The installer "failure" that is not a failure

NemoClaw's installer auto-runs `nemoclaw onboard`, which tries to stand up its
**own** vLLM and aborts when one already holds the port:

```
vLLM install failed: port 8000 is already in use by another process.
[ERROR] Onboarding did not complete successfully.
```

**This is expected and harmless.** The `nemoclaw` and `openshell` CLIs install
fine; only the bundled onboarding step fails, and `setup-agent.sh` does that
part properly against your existing model. Verify with `nemoclaw --version`,
then remove the installer's throwaway sandbox:

```bash
nemoclaw throwaway-init destroy --yes
```

Do **not** stop your vLLM to make the installer happy — that would download a
second ~20 GB model you do not need.

## Verified working

```
sandbox:   e2-agent (Debian 13, user `sandbox`, Python 3.13.5)
runtime:   Hermes Agent (NemoClaw v0.0.124 hermes-sandbox image)
model:     nvidia/Qwen3.6-35B-A3B-NVFP4 on the host vLLM
```

A real completion from inside the sandbox:

> *"Ensemble spread tells a forecaster the degree of uncertainty in the
> prediction, where a wide spread indicates low confidence due to diverging
> model runs and a narrow spread indicates high confidence in a consistent
> forecast."*

## Networking: the part that will bite you

Three separate failures sit between a fresh sandbox and a working inference
call. Each returns a *different* error, which is how you tell them apart:

| symptom | cause | fix |
|---|---|---|
| `403 policy_denied` | OpenShell deny-by-default egress | add a scoped policy preset |
| `502` / `upstream_unreachable` | routing — nothing listens at that address | see below |
| `{"error":"inference service unavailable"}` | gateway's managed route can't reach vLLM | same routing fix |

**The routing fix.** Two distinct traps, both of which look like "the server is
down" when it is running perfectly:

1. **vLLM binds `127.0.0.1` inside its container by default.** The host's `ss`
   reports `0.0.0.0:8000` (that's docker's published port), but every bridge
   address refuses. Launch vLLM with an explicit `--host 0.0.0.0`.
2. **`host.openshell.internal` resolves to the bridge *gateway*** (e.g.
   `172.18.0.1`), where nothing listens. Attach the vLLM container to the
   `openshell-docker` network and target **its own address** on that bridge:

   ```bash
   docker network connect openshell-docker vllm-server
   docker inspect vllm-server -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}'
   ```

   That IP can change when the container is recreated — `setup-agent.sh` looks
   it up each run rather than hardcoding it.

## Policy preset schema

User-supplied presets use `preset:` + `network_policies:` (see
`agent/e2-vllm-policy.yaml`). Two rules that cost a cycle each:

- A preset needs **both** a `preset.name` and a `network_policies` section.
  Missing either is rejected with a message naming only the first problem.
- User presets may **not** contain `allowed_ips` — built-in NVIDIA presets can,
  which makes copying one as a template misleading. Pass
  `--trusted-private-host <ip>` on `policy-add` instead.

## Status

The foundation is proven: sandbox, runtime, policy gate, and live inference all
verified end to end. The natural-language planning layer on top — "how much
stronger does this storm get if the sea surface warms two degrees?" mapped onto
a real ensemble run — is the next build.
