#!/usr/bin/env python3
"""Ask the sandboxed booth agent a question. Runs INSIDE the NemoClaw sandbox."""
import json, os, sys, urllib.request

# Resolved at call time by agent/ask.sh -- the vLLM container's address on the
# openshell bridge changes whenever the container is recreated.
VLLM_IP = os.environ.get("E2_VLLM_IP", "172.18.0.3")
URL = f"http://{VLLM_IP}:8000/v1/chat/completions"

# Facts go in a clearly-labelled reference block, NOT as free prose in the
# system prompt. With prose, the model treats the facts as the thing to
# present and answers every question with the same brochure recital.
FACTS = """SFNO = Spherical Fourier Neural Operator, 289 million parameters.
Grid: 0.25 degree global, 721 x 1440 points.
Ensemble: 6 members across 3 DGX Spark machines (2 per machine).
Ensemble spread, 2m temperature: 0.0004 K at hour 0; 3.15 K at 6h; 5.80 K at
  24h; 7.83 K mean at 48h, with a maximum of 41 K in the most volatile regions.
Per member: 16 GB memory, 1.79 seconds per 6-hour forecast step.
Six members, 5-day forecast: about 30 seconds total.
CorrDiff downscaling: 25 km to 2 km (11.8x finer) in 3.3 seconds.
Initial conditions: NOAA GFS. Limits: surrogate model, not physics; does not
  conserve mass/energy exactly; skill degrades past about 10 days."""

SYSTEM = (
    "You are the assistant at an NVIDIA booth at a supercomputing conference, "
    "talking to one visitor.\n\n"
    "RULES:\n"
    "1. ANSWER THE QUESTION ASKED. Do not recite an overview of the demo.\n"
    "2. Do not greet or welcome the visitor. Start with the answer.\n"
    "3. Two or three sentences. Plain prose, no bullet lists, no bold markup.\n"
    "4. Use a number from the reference only if it answers the question.\n"
    "5. Never invent a number or a name. If the reference does not cover it, "
    "say so plainly.\n\n"
    "REFERENCE FACTS (background only -- not a script to read out):\n" + FACTS
)

def ask(q, max_tokens=240):
    body = json.dumps({
        "model": "nvidia/Qwen3.6-35B-A3B-NVFP4",
        "messages": [{"role": "system", "content": SYSTEM},
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
