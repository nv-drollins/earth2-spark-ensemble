#!/usr/bin/env python3
"""Turn a plain-English question into a VALIDATED ensemble run plan.

Design rule: the model PROPOSES, code DISPOSES.

The model never touches the cluster. It emits a small JSON object describing
what to run; this module validates and clamps every field against hard limits
before anything executes. A malformed, missing, or absurd value degrades to a
safe default rather than failing the demo or launching a 400-member run.

Runs INSIDE the NemoClaw sandbox, which can reach the vLLM inference endpoint
and nothing else.
"""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.request

VLLM_IP = os.environ.get("E2_VLLM_IP", "172.18.0.3")
VLLM_PORT = os.environ.get("E2_VLLM_PORT", "8000")
def _served_model() -> str:
    """Ask the endpoint which model it serves.

    Hardcoding a model id breaks silently the moment the served model is
    swapped: the endpoint answers 404 and it looks like a network fault.
    """
    override = os.environ.get("E2_MODEL")
    if override:
        return override
    try:
        with urllib.request.urlopen(
                f"http://{VLLM_IP}:{VLLM_PORT}/v1/models", timeout=20) as r:
            return json.load(r)["data"][0]["id"]
    except Exception:
        return "nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4"


MODEL = _served_model()
URL = f"http://{VLLM_IP}:{VLLM_PORT}/v1/chat/completions"

# Hard limits. These are booth-safety rails, not suggestions: a visitor asking
# for "a hundred forecasts for the next year" must produce a runnable plan,
# not a wedged cluster.
LIMITS = {
    "members": (1, 12),      # 12 x 16 GB still fits 3 x 121 GB with headroom
    "steps":   (4, 40),      # 40 steps = 10 days, past which SFNO skill decays
    "noise":   (0.005, 0.05),  # >0.05 pushes members non-physical (see PITFALLS #11)
}
DEFAULTS = {"members": 6, "steps": 20, "noise": 0.02, "region": "global",
            "variable": "t2m", "downscale": False}

# Named regions the planner may select. Bounds are (lat_min, lat_max,
# lon_min, lon_max) in degrees, lon 0-360.
REGIONS = {
    "global":        (-90, 90, 0, 360),
    "north_atlantic": (5, 60, 260, 360),
    "caribbean":      (8, 32, 260, 305),
    "us_east_coast":  (24, 48, 275, 300),
    "europe":         (35, 72, 340, 40),
    "east_asia":      (18, 50, 100, 150),
    "taiwan":         (19, 28, 116, 126),   # CorrDiff's trained domain
    "australia":     (-45, -8, 110, 156),
    "arctic":         (66, 90, 0, 360),
    "antarctic":     (-90, -60, 0, 360),
}

SYSTEM = f"""You convert a visitor's plain-English question into a forecast run plan.

Respond with ONLY a JSON object. No prose, no markdown fences, no explanation.

Schema:
{{
  "members":   integer 1-12,      how many ensemble forecasts to run
  "steps":     integer 4-40,      number of 6-hour steps (4 steps = 1 day)
  "noise":     number 0.005-0.05, how much to perturb the starting conditions
  "region":    one of {sorted(REGIONS)},
  "variable":  one of ["t2m", "msl", "z500", "u10m", "v10m", "mrr"],
  "downscale": true or false,     true only if they ask for fine/local detail
  "intent":    one short sentence, what the visitor actually wants to see
}}

Guidance:
- "how uncertain / how much do we trust it" -> more members (8-12).
- "next week / 7 days" -> steps 28. "tomorrow" -> steps 4. "two days" -> 8.
- "what if conditions were slightly different" -> raise noise toward 0.05.
- "zoom in / rain bands / local detail / storm structure" -> downscale true
  and region taiwan (the only domain the downscaling model was trained on).
- Storms/hurricanes -> pick the matching ocean region, more members.
- temperature -> t2m; pressure/storms -> msl; upper air/jet stream -> z500;
  wind -> u10m or v10m.
- RAIN, rainfall, precipitation, rain bands, showers, storms you can SEE ->
  variable "mrr" AND downscale true AND region taiwan. Rainfall is produced by
  the downscaling model, not by the global forecast, so those three go together.
- If the question does not specify something, choose a sensible default."""


def _extract_json(text: str) -> dict:
    """Pull the first JSON object out of a model response.

    Models wrap JSON in prose or ```json fences even when told not to, so
    never json.loads() the raw string.
    """
    if not text:
        return {}
    fence = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.S)
    if fence:
        text = fence.group(1)
    start = text.find("{")
    if start < 0:
        return {}
    depth = 0
    for i, ch in enumerate(text[start:], start):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(text[start:i + 1])
                except json.JSONDecodeError:
                    return {}
    return {}


def _clamp(name: str, value, out: list) -> float | int:
    lo, hi = LIMITS[name]
    try:
        v = float(value)
    except (TypeError, ValueError):
        out.append(f"{name}: not a number, using default {DEFAULTS[name]}")
        return DEFAULTS[name]
    if name in ("members", "steps"):
        v = int(round(v))
    if v < lo:
        out.append(f"{name}: raised {v} -> {lo} (minimum)")
        return lo
    if v > hi:
        out.append(f"{name}: capped {v} -> {hi} (maximum)")
        return hi
    return v


def validate(raw: dict) -> dict:
    """Clamp a proposed plan into something safe to execute."""
    notes: list[str] = []
    plan = dict(DEFAULTS)

    for key in ("members", "steps", "noise"):
        if key in raw:
            plan[key] = _clamp(key, raw[key], notes)

    region = str(raw.get("region", "global")).strip().lower().replace(" ", "_")
    if region not in REGIONS:
        notes.append(f"region: unknown '{region}', using global")
        region = "global"
    plan["region"] = region
    plan["bounds"] = REGIONS[region]

    plan["downscale"] = bool(raw.get("downscale", False))
    # CorrDiff is only trained on its Taiwan domain; downscaling anywhere else
    # would be fabrication dressed up as a result.
    if plan["downscale"] and plan["region"] not in ("taiwan", "east_asia"):
        notes.append(f"downscale: not available for {plan['region']} "
                     "(CorrDiff is trained on the Taiwan domain only) -- disabled")
        plan["downscale"] = False

    variable = str(raw.get("variable", "t2m")).strip().lower()
    if variable not in ("t2m", "msl", "z500", "u10m", "v10m", "mrr"):
        notes.append(f"variable: unknown '{variable}', using t2m")
        variable = "t2m"
    plan["variable"] = variable

    # Rainfall (mrr) exists ONLY in the CorrDiff output -- the global SFNO
    # forecast has no precipitation variable at all. Asking for rain without
    # downscaling would silently show temperature instead, which is exactly the
    # kind of quiet wrongness a meteorologist spots first.
    if variable == "mrr":
        if not raw.get("downscale", False):
            notes.append("rainfall comes from the downscaling model -- "
                         "enabling downscale")
        plan["downscale"] = True
        if str(raw.get("region", "")).strip().lower() not in ("taiwan", "east_asia"):
            notes.append("rainfall is only available in the CorrDiff domain -- "
                         "switching region to taiwan")
        plan["region"] = "taiwan"
        plan["bounds"] = REGIONS["taiwan"]

    plan["intent"] = str(raw.get("intent", "")).strip()[:200]

    # Runtime estimate from measured numbers: 1.79 s per 6-hour step per
    # member, 6 members across 3 nodes = 2 waves, ~10 s model load per wave.
    waves = (plan["members"] + 2) // 3
    plan["estimate_s"] = round(waves * (plan["steps"] * 1.79 + 10)
                               + (3.3 if plan["downscale"] else 0))
    plan["notes"] = notes
    return plan


def propose(question: str, timeout: int = 180) -> dict:
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "system", "content": SYSTEM},
                     {"role": "user", "content": question}],
        "max_tokens": 400,
        "temperature": 0.2,
        "chat_template_kwargs": {"enable_thinking": False},
    }).encode()
    req = urllib.request.Request(URL, data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = json.load(r)
    text = data["choices"][0]["message"].get("content") or ""
    raw = _extract_json(text)
    plan = validate(raw)
    plan["question"] = question
    if not raw:
        plan["notes"].append("model returned no usable JSON -- using defaults")
    return plan


if __name__ == "__main__":
    print(json.dumps(propose(" ".join(sys.argv[1:])), indent=2))
