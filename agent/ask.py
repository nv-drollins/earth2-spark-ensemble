#!/usr/bin/env python3
"""Ask the sandboxed booth agent a question. Runs INSIDE the NemoClaw sandbox."""
import json, os, sys, urllib.request

# Resolved at call time by agent/ask.sh -- the vLLM container's address on the
# openshell bridge changes whenever the container is recreated.
VLLM_IP = os.environ.get("E2_VLLM_IP", "172.18.0.3")
VLLM_PORT = os.environ.get("E2_VLLM_PORT", "8000")


def _served_model() -> str:
    """Ask the endpoint which model it serves (see plan.py for rationale)."""
    override = os.environ.get("E2_MODEL")
    if override:
        return override
    try:
        with urllib.request.urlopen(
                f"http://{VLLM_IP}:{VLLM_PORT}/v1/models", timeout=20) as r:
            return json.load(r)["data"][0]["id"]
    except Exception:
        return "nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4"
URL = f"http://{VLLM_IP}:8000/v1/chat/completions"

# Facts go in a clearly-labelled reference block, NOT as free prose in the
# system prompt. With prose, the model treats the facts as the thing to
# present and answers every question with the same brochure recital.
# Static facts about the STACK -- these do not change between runs.
STATIC_FACTS = """SFNO = Spherical Fourier Neural Operator, 289 million parameters.
Grid: 0.25 degree global, 721 x 1440 points.
Runs on DGX Spark (GB10) nodes; each member needs 16 GB and about 1.79 s per
  6-hour forecast step.
SFNO forecasts the WHOLE GLOBE. It has no regional restriction.
CorrDiff is a SEPARATE, OPTIONAL zoom-in step. Only CorrDiff is limited to the
  Taiwan domain; that limit does NOT apply to the global forecast. CorrDiff
  downscales roughly 25 km to 2 km (about 12x finer) in ~3.3 s.
Never say the system or SFNO is trained only on Taiwan -- that is false and
  only CorrDiff has that constraint.
Initial conditions: NOAA GFS.
Limits: surrogate model, not physics; does not conserve mass/energy exactly;
  skill degrades past about 10 days. This is inference, not training."""


def _live_facts() -> str:
    """Read the CURRENT run's numbers from the render manifest.

    Hardcoding measured values guarantees the agent eventually contradicts the
    screen: a visitor reads 2.19 K on the display while the agent recites 5.80 K
    from an older run. Worse, it reads as a hallucination when it is really a
    stale constant. Fall back to describing the shape of the result rather than
    inventing numbers when no manifest is available.
    """
    # Preferred path: agent/ask.sh reads the manifest on the workstation and
    # injects it here, because the sandbox cannot see the workstation's disk.
    injected = os.environ.get("E2_LIVE_FACTS_B64", "").strip()
    if injected:
        try:
            import base64 as _b64
            return _b64.b64decode(injected).decode()
        except Exception:
            pass
    path = os.environ.get(
        "E2_MANIFEST",
        os.path.expanduser("~/e2viz/frames/manifest.json"))
    try:
        with open(path) as fh:
            m = json.load(fh)
        curve = m.get("curve") or []
        if not curve:
            raise ValueError("no curve")
        first, last = curve[0], curve[-1]
        lines = [
            f"CURRENT RUN (these are the numbers on the display right now):",
            f"  {len(m.get('members', []))} ensemble members.",
            f"  Forecast horizon {last['lead_h']} hours "
            f"({len(curve) - 1} steps of 6 hours).",
            f"  Ensemble spread in 2m temperature: {first['mean_K']} K at hour 0, "
            f"rising to {last['mean_K']} K at {last['lead_h']} h "
            f"(maximum {last['max_K']} K in the most volatile regions).",
        ]
        mids = [r for r in curve if r["lead_h"] in (24, 48)]
        for r in mids:
            lines.append(f"  At {r['lead_h']} h the mean spread is {r['mean_K']} K.")
        cd = m.get("corrdiff") or {}
        if cd.get("resolution_gain"):
            lines.append(f"  CorrDiff downscaling gain this run: "
                         f"{cd['resolution_gain']}x.")
        return "\n".join(lines)
    except Exception:
        return ("CURRENT RUN: no run data available. Describe the behaviour "
                "qualitatively (spread starts near zero and grows with lead "
                "time) and do NOT quote specific numbers.")


def _system() -> str:
    return (
    "You are the assistant at an NVIDIA booth at a supercomputing conference, "
    "talking to one visitor.\n\n"
    "RULES:\n"
    "1. ANSWER THE QUESTION ASKED. Do not recite an overview of the demo.\n"
    "2. Do not greet or welcome the visitor. Start with the answer.\n"
    "3. TWO SENTENCES MAXIMUM, under 45 words total. The answer is shown on a\n"
    "   booth screen and anything longer is cut off. Plain prose, no bullet\n"
    "   lists, no bold markup.\n"
    "4. Use a number from the reference only if it answers the question.\n"
    "5. Never invent a number or a name. If the reference does not cover it, "
    "say so plainly.\n"
    "6. If they are ASKING FOR A FORECAST or for something to be shown or run "
    "(\"what is the weather tomorrow\", \"will the hurricane hit Florida\", "
    "\"show me the pressure field\"), do NOT refuse and do NOT lecture them "
    "about model limitations. Say in one sentence that the demo can run that, "
    "and that the Plan button turns their question into a real ensemble run "
    "on the three Sparks. Then add one short sentence of useful context.\n\n"
    "REFERENCE FACTS (background only -- not a script to read out):\n"
    + STATIC_FACTS + "\n\n" + _live_facts()
)

def ask(q, max_tokens=240):
    body = json.dumps({
        "model": _served_model(),
        "messages": [{"role": "system", "content": _system()},
                     {"role": "user", "content": q}],
        "max_tokens": max_tokens,
        "temperature": 0.3,
        "chat_template_kwargs": {"enable_thinking": False},
    }).encode()
    req = urllib.request.Request(URL, data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as r:
        d = json.load(r)
    return d["choices"][0]["message"]["content"]

if __name__ == "__main__":
    print(ask(" ".join(sys.argv[1:])))
