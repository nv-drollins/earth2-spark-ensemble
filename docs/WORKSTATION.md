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
- **Key-based SSH to every Spark** — `ssh-copy-id nvidia@<spark>`
- Python packages from `viz/requirements.txt`
- Network reachability to the Sparks and to the booth display screen

Windows is untested. Use WSL2 if that is all you have.

---

## Install

```bash
git clone https://github.com/nv-drollins/earth2-spark-ensemble.git
cd earth2-spark-ensemble

python3 -m venv .venv && source .venv/bin/activate    # optional but tidy
pip install -r viz/requirements.txt

cp cluster.conf.example cluster.conf
$EDITOR cluster.conf        # set NODES to your SSH targets

ssh-copy-id nvidia@<spark-1>   # repeat for each node
./demo check                   # verifies SSH, GPUs, disk, image, agent
```

`./demo check` is the real test. It exercises every dependency this machine
has and reports each node's readiness.

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

## Troubleshooting

| symptom | cause | fix |
|---|---|---|
| `./demo check` fails on SSH | no key-based auth | `ssh-copy-id nvidia@<node>` |
| `Missing Python packages` | venv not active | `pip install -r viz/requirements.txt` |
| Display loads but globes are blank | no frames rendered | `./scripts/collect.sh && python3 viz/render.py` |
| Changes to HTML/CSS do nothing | browser cache | hard-refresh (Ctrl+Shift+R); routes already send `no-store` |
| Agent panel errors | LLM still loading | wait 4-6 min, `./demo status` |
| Port already in use | another copy running | `./viz/stop-display.sh` or set `E2_PORT` |
