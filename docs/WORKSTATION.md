# Workstation Setup

The machine that drives the booth display. **This is not a Spark.**

---

## What this machine does

| | |
|---|---|
| Renders globe frames, spread maps, CorrDiff panels | numpy + PIL |
| Serves `/display` and `/operator` | FastAPI + uvicorn |
| Collects member output from the Sparks | scp over SSH |
| Drives the cluster (`./demo`, `ensemble.sh`) | bash + ssh |

## What it does NOT need

- **No GPU.** Rendering is pure numpy/PIL on the CPU. A 900x900 globe takes
  ~290 ms; a full 6-member x 9-lead render is ~19 s on a modest laptop.
- **No CUDA, no Docker, no NVIDIA drivers.** All GPU work happens on the Sparks
  inside their container.
- **No large disk.** Frames are ~10 MB; collected member arrays ~220 MB.

A laptop is genuinely sufficient. A workstation with a big GPU will work fine
but the GPU sits idle — unless you deliberately move the agent's LLM onto it
(see "Freeing the third Spark" below).

---

## Requirements

- Linux or macOS (bash, ssh, scp, python3.9+)
- **Key-based SSH to every Spark** — `ssh-copy-id <user>@<spark>`
- Python packages from `viz/requirements.txt`
- Network reachability to the Sparks and to the booth display screen

Windows is untested. Use WSL2 if that is all you have.

---

## Install

```bash
git clone https://github.com/nv-drollins/earth2-spark-ensemble.git
cd earth2-spark-ensemble

python3 -m venv .venv                      # REQUIRED on Ubuntu 24.04+ (PEP 668)
.venv/bin/pip install -r viz/requirements.txt

cp cluster.conf.example cluster.conf
$EDITOR cluster.conf        # set NODES to your SSH targets

ssh-copy-id <user>@<spark-1>   # repeat for each node
./demo check                   # verifies SSH, GPUs, disk, image, agent
```

`./demo check` is the real test. It exercises every dependency this machine
has and reports each node's readiness.

---

## Complete footprint (for rebuilding on a clean machine)

Everything this project puts on the workstation, exhaustively. Nothing is
installed system-wide; nothing needs root.

### From the OS (present on any stock Linux/macOS)

`git`, `ssh`, `scp`, `python3` (3.9+), `curl`, `bash`. No compilers, no CUDA,
no Docker, no NVIDIA anything.

### Python packages — all inside `.venv/`, nothing system-wide

Five direct deps from `viz/requirements.txt`, 19 packages with transitives,
**~125 MB**:

| direct | pulls in |
|---|---|
| `fastapi` | starlette, pydantic, pydantic_core, annotated-types, annotated-doc, typing-inspection, opentelemetry-api |
| `uvicorn` | click, h11, anyio, idna |
| `jinja2` | MarkupSafe |
| `pillow` | — |
| `numpy` | — |

Delete `.venv/` and this machine is back to stock. Rebuild with the two
commands under [Install](#install).

### Files written outside the repo

| path | what | size |
|---|---|---|
| `~/e2viz/data/` | member arrays pulled by `collect.sh` | ~37 MB per member (~220 MB for 6) |
| `~/e2viz/frames/` | rendered PNGs + `manifest.json` | ~10 MB |
| `~/.ssh/` | your key for the Sparks (`ssh-copy-id`) | — |
| `/tmp/e2-display.log` | uvicorn log | small |

Both `~/e2viz` paths are regenerable: re-run `collect.sh` and `render.py`.
Override with `E2_DATA` / `E2_FRAMES`.

### Inside the repo clone

| path | committed? |
|---|---|
| `.venv/` | no — gitignored |
| `cluster.conf` | no — gitignored, site-specific |
| everything else | yes |

### Rebuild on a clean machine

```bash
git clone https://github.com/nv-drollins/earth2-spark-ensemble.git
cd earth2-spark-ensemble
python3 -m venv .venv && .venv/bin/pip install -r viz/requirements.txt
cp cluster.conf.example cluster.conf && $EDITOR cluster.conf
ssh-copy-id <user>@<each-spark>
./demo check
```

Then `collect.sh` + `render.py` to repopulate the frames. No state on the old
workstation is irreplaceable — the Sparks hold everything that matters.

---

## Two directories outside the repo

Deliberately not in git — they are data, not code, and they survive reboots:

| path | what | size | override |
|---|---|---|---|
| `~/e2viz/data` | collected member arrays + land mask | ~220 MB | `E2_DATA` |
| `~/e2viz/frames` | rendered frames + `manifest.json` | ~10 MB | `E2_FRAMES` |

**Frames survive a reboot**, so after restarting you only need
`./demo start` — no re-render unless you ran a new ensemble.

---

## Running it

```bash
./demo start     # display server up, agent LLM kicked off in the background
./demo status    # URLs + node readiness
./demo stop
```

Then open:

- **`/display`** on the aisle-facing screen, fullscreen (F11)
- **`/operator`** on this machine

Override the port with `E2_PORT` if 8500 is taken.

### Browser notes for the booth screen

- **Fullscreen/kiosk mode.** Chrome: `--kiosk --app=http://<host>:8500/display`
- **Disable screen blanking** on the display machine. Nothing is more
  embarrassing than a black screen at 2pm.
- The display polls every 400 ms and holds one strip image per globe; memory is
  flat over a show day.

---

## Freeing the third Spark for forecasting

By default the third Spark hosts the agent's ~30B LLM, which leaves ~15 GB of
its 128 GB unified memory free. An SFNO member needs 16 GB, so
`scripts/ensemble.sh` **skips that node** and splits members across the other
two. This is reported by `./demo status`, not silent.

If you want all three Sparks forecasting, move the LLM to a GPU workstation:

1. Serve the model there (needs ~24 GB VRAM for the NVFP4 30B):
   ```bash
   docker run -d --name e2-llm --gpus all --ipc=host -p 0.0.0.0:8000:8000 \
     -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
     vllm/vllm-openai:latest \
     nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4 \
     --host 0.0.0.0 --port 8000 --max-model-len 32768 \
     --reasoning-parser nemotron_v3
   ```
   Note the image ENTRYPOINT is already `["vllm","serve"]` — pass only the
   model id and flags (see docs/AGENT.md).
2. Point the agent at it: `export E2_AGENT_NODE=<user>@<workstation>`
3. Re-run `./agent/setup-agent.sh`

All three Sparks then pass the memory check and you get 3 members each.

**Is it worth it?** Six members across two nodes already tells the story, and
the extra node buys ~1.5x more members, not a better demo. Do it only if you
already have the workstation.

---

## Limited hardware: hosting the controller ON a Spark

There is nothing in the viz stack that needs a separate machine — it is numpy,
PIL and FastAPI, all fine on ARM64. If you are carrying three Sparks and no
fourth box, one Spark can drive the display.

**Choose the Spark that hosts the agent LLM.** It is already excluded from the
ensemble on memory grounds, so it has CPU headroom for rendering that the
forecasting nodes do not.

### The one real prerequisite: node-to-node SSH

The controller needs key-based SSH to **every** node *including itself*. Your
workstation already has this; the Sparks do not have keys to each other.

```bash
# ON the Spark you have chosen as controller
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519      # if it has no key yet
ssh-copy-id <user>@<spark-1>     # yes, including itself
ssh-copy-id <user>@<spark-2>
ssh-copy-id <user>@<spark-3>

git clone https://github.com/nv-drollins/earth2-spark-ensemble.git
cd earth2-spark-ensemble
python3 -m venv .venv && .venv/bin/pip install -r viz/requirements.txt
cp cluster.conf.example cluster.conf && $EDITOR cluster.conf
./demo check
```

Everything then works identically — `./demo` does not care which machine it
runs on.

### Run the display BROWSER on something else

Even with the controller on a Spark, point a laptop at
`http://<spark>:8500/display`. A browser running on the Spark shares the GB10
GPU with the model, and the globe animation stutters. Any cheap laptop renders
it smoothly.

### What you give up

**The display stops surviving the cluster.** Today the workstation caches every
rendered frame, so you can power off all three Sparks mid-conversation and the
globes, spread map, scrub control and CorrDiff comparison keep working — only
live re-runs are lost. Put the controller on a Spark and that safety net goes
with it: the node that dies takes the display with it.

On a show floor that property is worth more than one less box. Use the
Spark-hosted layout when hardware is genuinely constrained, not by default.

## Troubleshooting

| symptom | cause | fix |
|---|---|---|
| `./demo check` fails on SSH | no key-based auth | `ssh-copy-id <user>@<node>` |
| `Missing Python packages` | deps not installed locally; on Ubuntu 24.04+ plain `pip` refuses (PEP 668 `externally-managed-environment`) | `python3 -m venv .venv && .venv/bin/pip install -r viz/requirements.txt` — `start-display.sh` finds `.venv` automatically |
| Display loads but globes are blank | no frames rendered | `./scripts/collect.sh && python3 viz/render.py` |
| Changes to HTML/CSS do nothing | browser cache | hard-refresh (Ctrl+Shift+R); routes already send `no-store` |
| Agent panel errors | LLM still loading | wait 4-6 min, `./demo status` |
| Port already in use | another copy running | `./viz/stop-display.sh` or set `E2_PORT` |
| Agent errors after a reboot | sandbox in `Error` phase | `./demo start` heals it automatically; or `./agent/setup-agent.sh` |
| Node pings but SSH refused | shutdown stalled on a container stop | wait ~3 min; it clears. Use `./demo shutdown` next time |
