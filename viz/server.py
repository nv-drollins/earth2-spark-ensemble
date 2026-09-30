"""Booth display server for the Earth-2 ensemble demo.

Serves two pages:
  /display   aisle-facing. Big globes, spread map, chaos curve. No controls.
  /operator  presenter-facing. Buttons to advance beats, launch runs, reset.

Deliberately NOT a live-inference server -- it renders and serves frames that
the cluster already produced. Keeps the booth display immune to a cluster
hiccup mid-conversation.
"""
from __future__ import annotations

import json
import os
import subprocess
import threading
import time

from fastapi import FastAPI
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
import jinja2

BASE = os.path.dirname(os.path.abspath(__file__))
FRAMES = os.environ.get("E2_FRAMES", os.path.expanduser("~/e2viz/frames"))
REPO = os.path.dirname(BASE)

app = FastAPI(title="Earth-2 Ensemble Booth Display")
if os.path.isdir(FRAMES):
    app.mount("/frames", StaticFiles(directory=FRAMES), name="frames")

env = jinja2.Environment(loader=jinja2.FileSystemLoader(os.path.join(BASE, "templates")))

# --- demo state ------------------------------------------------------------
# Beats drive the narrative. The operator advances them; the display follows.
BEATS = [
    {"id": "idle",     "label": "Idle / attract",        "lead": 0},
    {"id": "single",   "label": "1. One forecast",       "lead": 0},
    {"id": "ensemble", "label": "2. Six members",        "lead": 0},
    {"id": "diverge",  "label": "3. Watch them diverge", "lead": -1},
    {"id": "spread",   "label": "4. Where it's unsure",  "lead": -1},
    {"id": "zoom",     "label": "5. Zoom in (CorrDiff)",  "lead": -1},
]

STATE = {
    "beat": "idle",
    "lead": 0,
    "playing": False,
    "run": {"status": "idle", "detail": "", "started": 0.0},
    # Last agent interaction, surfaced on BOTH the operator console and the
    # aisle display -- a visitor should see the question and the plan, never a
    # terminal.
    "agent": {"status": "idle", "question": "", "answer": "",
              "plan": None, "error": ""},
}
_lock = threading.Lock()


def manifest() -> dict:
    path = os.path.join(FRAMES, "manifest.json")
    if not os.path.isfile(path):
        man = {"members": [], "n_lead": 0, "curve": [], "frames": {}}
    else:
        with open(path) as fh:
            man = json.load(fh)
    # CorrDiff is optional: the demo runs fine without it, the zoom beat just
    # has nothing to show.
    cd_path = os.path.join(FRAMES, "corrdiff_manifest.json")
    if os.path.isfile(cd_path):
        with open(cd_path) as fh:
            man["corrdiff"] = json.load(fh)
    return man


# Cache-Control: no-store on the HTML routes. Without it a booth kiosk or a
# recording browser keeps serving a cached page and your CSS/JS changes
# silently do not appear -- you end up debugging code that is not running.
_NOCACHE = {"Cache-Control": "no-store, no-cache, must-revalidate",
            "Pragma": "no-cache"}


@app.get("/", response_class=HTMLResponse)
@app.get("/display", response_class=HTMLResponse)
async def display() -> HTMLResponse:
    return HTMLResponse(env.get_template("display.html").render(),
                        headers=_NOCACHE)


@app.get("/operator", response_class=HTMLResponse)
async def operator() -> HTMLResponse:
    return HTMLResponse(env.get_template("operator.html").render(beats=BEATS),
                        headers=_NOCACHE)


@app.get("/api/state")
async def get_state() -> JSONResponse:
    man = manifest()
    with _lock:
        st = dict(STATE)
    n = man.get("n_lead", 0)
    lead = st["lead"]
    if lead < 0:
        lead = max(n - 1, 0)
    st["lead"] = max(0, min(lead, max(n - 1, 0)))
    st["manifest"] = man
    return JSONResponse(st)


@app.post("/api/beat/{beat_id}")
async def set_beat(beat_id: str) -> JSONResponse:
    known = {b["id"] for b in BEATS}
    if beat_id not in known:
        return JSONResponse({"error": f"unknown beat {beat_id}"}, status_code=400)
    man = manifest()
    with _lock:
        STATE["beat"] = beat_id
        spec = next(b for b in BEATS if b["id"] == beat_id)
        STATE["lead"] = (man.get("n_lead", 1) - 1) if spec["lead"] < 0 else spec["lead"]
        STATE["playing"] = False
    return JSONResponse({"ok": True, "beat": beat_id})


@app.post("/api/lead/{lead}")
async def set_lead(lead: int) -> JSONResponse:
    man = manifest()
    with _lock:
        STATE["lead"] = max(0, min(lead, max(man.get("n_lead", 1) - 1, 0)))
        STATE["playing"] = False
    return JSONResponse({"ok": True, "lead": STATE["lead"]})


@app.post("/api/play")
async def play() -> JSONResponse:
    """Advance lead time on a paced timer -- the divergence beat."""
    man = manifest()
    n = man.get("n_lead", 0)
    if n < 2:
        return JSONResponse({"error": "no frames rendered"}, status_code=400)

    def _run() -> None:
        for lead in range(n):
            with _lock:
                if not STATE["playing"]:
                    return
                STATE["lead"] = lead
            time.sleep(1.4)
        with _lock:
            STATE["playing"] = False

    with _lock:
        if STATE["playing"]:
            return JSONResponse({"ok": True, "already": True})
        STATE["playing"] = True
        STATE["lead"] = 0
    threading.Thread(target=_run, daemon=True).start()
    return JSONResponse({"ok": True})


@app.post("/api/stop")
async def stop() -> JSONResponse:
    with _lock:
        STATE["playing"] = False
    return JSONResponse({"ok": True})


@app.post("/api/run")
async def run_ensemble() -> JSONResponse:
    """Launch a REAL ensemble on the cluster, then re-render frames.

    Backgrounded so the operator page returns instantly; progress is polled
    via /api/state.
    """
    with _lock:
        if STATE["run"]["status"] == "running":
            return JSONResponse({"ok": True, "already": True})
        STATE["run"] = {"status": "running", "detail": "launching ensemble", "started": time.time()}

    def _work() -> None:
        try:
            env2 = dict(os.environ, MEMBERS=os.environ.get("E2_MEMBERS", "6"),
                        STEPS=os.environ.get("E2_STEPS", "8"))
            r = subprocess.run(["bash", os.path.join(REPO, "scripts", "ensemble.sh")],
                               capture_output=True, text=True, timeout=3600, env=env2)
            if r.returncode != 0:
                with _lock:
                    STATE["run"] = {"status": "error", "detail": r.stderr[-400:], "started": 0.0}
                return
            with _lock:
                STATE["run"]["detail"] = "collecting output"
            subprocess.run(["bash", os.path.join(REPO, "scripts", "collect.sh")],
                           capture_output=True, text=True, timeout=1200)
            with _lock:
                STATE["run"]["detail"] = "rendering frames"
            subprocess.run(["python3", os.path.join(REPO, "viz", "render.py")],
                           capture_output=True, text=True, timeout=1800)
            with _lock:
                STATE["run"] = {"status": "done", "detail": "ready", "started": 0.0}
        except Exception as exc:  # keep the booth alive no matter what
            with _lock:
                STATE["run"] = {"status": "error", "detail": str(exc)[:400], "started": 0.0}

    threading.Thread(target=_work, daemon=True).start()
    return JSONResponse({"ok": True})


# --- agent: ask + plan + run ----------------------------------------------

def _agent_script(name: str) -> str:
    return os.path.join(REPO, "agent", name)


@app.post("/api/agent/ask")
async def agent_ask(q: str = "") -> JSONResponse:
    """Answer a visitor question about the demo (no cluster work)."""
    q = (q or "").strip()
    if not q:
        return JSONResponse({"error": "empty question"}, status_code=400)
    with _lock:
        if STATE["agent"]["status"] == "busy":
            return JSONResponse({"ok": True, "already": True})
        STATE["agent"] = {"status": "busy", "question": q, "answer": "",
                          "plan": None, "error": ""}

    def _work() -> None:
        try:
            r = subprocess.run(["bash", _agent_script("ask.sh"), q],
                               capture_output=True, text=True, timeout=300)
            answer = (r.stdout or "").strip()
            with _lock:
                if r.returncode == 0 and answer:
                    STATE["agent"].update(status="done", answer=answer)
                else:
                    STATE["agent"].update(
                        status="error",
                        error=(r.stderr or "no answer returned")[-300:])
        except Exception as exc:
            with _lock:
                STATE["agent"].update(status="error", error=str(exc)[:300])

    threading.Thread(target=_work, daemon=True).start()
    return JSONResponse({"ok": True})


@app.post("/api/agent/plan")
async def agent_plan(q: str = "", execute: bool = False) -> JSONResponse:
    """Turn a question into a validated plan; optionally run it for real."""
    q = (q or "").strip()
    if not q:
        return JSONResponse({"error": "empty question"}, status_code=400)
    with _lock:
        if STATE["agent"]["status"] == "busy":
            return JSONResponse({"ok": True, "already": True})
        STATE["agent"] = {"status": "busy", "question": q, "answer": "",
                          "plan": None, "error": ""}
        if execute:
            STATE["run"] = {"status": "running", "detail": "planning",
                            "started": time.time()}

    def _work() -> None:
        try:
            # Always plan first so the UI can show the plan even when the
            # operator chose to execute -- a plan that appears only after a
            # 4-minute run is useless on stage.
            r = subprocess.run(["bash", _agent_script("run-plan.sh"),
                                "--dry-run", q],
                               capture_output=True, text=True, timeout=300)
            plan = _parse_plan(r.stdout or "")
            with _lock:
                STATE["agent"].update(plan=plan)
                if not plan:
                    STATE["agent"].update(
                        status="error",
                        error=(r.stderr or r.stdout or "no plan")[-300:])
                    STATE["run"] = {"status": "idle", "detail": "", "started": 0.0}
            if not plan:
                return
            if not execute:
                with _lock:
                    STATE["agent"].update(status="done")
                return

            with _lock:
                STATE["run"]["detail"] = "running ensemble"
            r2 = subprocess.run(["bash", _agent_script("run-plan.sh"), q],
                                capture_output=True, text=True, timeout=5400)
            with _lock:
                if r2.returncode == 0:
                    STATE["agent"].update(status="done")
                    STATE["run"] = {"status": "done", "detail": "ready",
                                    "started": 0.0}
                else:
                    STATE["agent"].update(status="error",
                                          error=(r2.stderr or "")[-300:])
                    STATE["run"] = {"status": "error",
                                    "detail": (r2.stderr or "")[-200:],
                                    "started": 0.0}
        except Exception as exc:
            with _lock:
                STATE["agent"].update(status="error", error=str(exc)[:300])
                STATE["run"] = {"status": "error", "detail": str(exc)[:200],
                                "started": 0.0}

    threading.Thread(target=_work, daemon=True).start()
    return JSONResponse({"ok": True})


def _parse_plan(text: str) -> dict | None:
    """Scrape the human-readable plan block from run-plan.sh output.

    The script is the single source of truth for planning; re-implementing the
    sandbox call here would give two code paths that can disagree.
    """
    out: dict = {"adjusted": []}
    keys = {"intent": "intent", "ensemble": "members", "horizon": "horizon",
            "perturbation": "noise", "region": "region",
            "variable": "variable", "downscale": "downscale",
            "estimate": "estimate"}
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("adjusted"):
            out["adjusted"].append(s.split(None, 1)[-1].strip())
            continue
        parts = s.split(None, 1)
        if len(parts) == 2 and parts[0] in keys:
            out[keys[parts[0]]] = parts[1].strip()
    return out if "members" in out else None


@app.post("/api/agent/clear")
async def agent_clear() -> JSONResponse:
    with _lock:
        STATE["agent"] = {"status": "idle", "question": "", "answer": "",
                          "plan": None, "error": ""}
    return JSONResponse({"ok": True})
