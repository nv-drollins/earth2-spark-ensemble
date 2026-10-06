# earth2-spark-ensemble

Reproducible **NVIDIA Earth-2** weather-forecasting stack for a cluster of
**DGX Spark / GB10** systems, built for live demonstration at venues with poor
or no internet.

Builds the image **once**, exports it as a single portable tarball, and loads it
onto every node. No per-node internet, no pip resolution at the venue.

Everything in here was verified on real GB10 hardware -- measured numbers below
are from actual runs, not estimates.

---

## What it runs

**SFNO** (Spherical Fourier Neural Operator) global weather forecasting via
[Earth2Studio](https://github.com/NVIDIA/earth2studio), on top of the official
NGC **PhysicsNeMo** container.

SFNO rather than FourCastNet deliberately: FourCastNet is numerically unstable
at the South Pole and diverges to **-1104 K** by 48 h, while SFNO stays
physically bounded. See [docs/PITFALLS.md](docs/PITFALLS.md#9-fourcastnet-is-numerically-unstable-at-the-south-pole--use-sfno).

## Measured performance (GB10, 720x1440 global grid)

| Metric | SFNO | FourCastNet |
|---|---|---|
| Parameters | 289.4 M | 75.3 M |
| Model load (cold) | 75.1 s | 7.6 s |
| Time per 6 h step | **1.79 s** | 0.69 s |
| GPU peak memory | **16.0 GB** | 1.2 GB |
| 5-day forecast (20 steps) | ~36 s | ~14 s |

With 121 GB unified memory per Spark: **~7 concurrent SFNO members per node**,
**~21 across three Sparks**.

| Artifact | Size |
|---|---|
| Built image | 48.8 GB |
| Exported tarball (`zstd -3`) | **14.1 GB** (~2 min 54 s to produce) |
| SFNO weights (cached separately) | 6.9 GB |

Budget **~80 GB free disk per node**.

### Verified 6-member ensemble across 3 Sparks

Round-robin scheduling, `MEMBERS=6 STEPS=8`:

| member | mean t2m | min | max | s/step | GPU peak |
|---|---|---|---|---|---|
| 0 (control) | 279.67 K | 197.33 | 318.53 | 2.95 s | 16.02 GB |
| 1 | 280.33 K | 190.09 | 322.45 | 2.78 s | 16.32 GB |
| 2 | 277.64 K | 133.51 | 344.87 | 4.76 s | 16.32 GB |
| 3 | 279.82 K | 182.60 | 322.37 | 3.09 s | 16.32 GB |
| 4 | 280.17 K | 197.15 | 328.15 | 3.00 s | 16.32 GB |
| 5 | 279.85 K | 198.55 | 334.88 | 5.21 s | 16.32 GB |

6/6 members distinct, **2.69 K ensemble mean spread** -- a real forecast
spread, not 6 copies of the same run. (Table taken at `--noise 0.05`; the
default is now 0.02, which keeps the tail members tighter.)

---

## Requirements

- 1 or more DGX Spark / GB10 nodes (`aarch64`), Ubuntu 24.04
- NVIDIA driver + Docker + NVIDIA Container Toolkit on each node
- Key-based SSH from your workstation to each node (`ssh-copy-id`)
- `zstd` on each node
- Internet on the **build node only**, once

Passwordless sudo is **not** required. Scripts probe for docker-group
membership, fall back to `sudo -n`, and report clearly if neither works rather
than hanging on a password prompt.

---

## How it is set up

You need **two kinds of machine**: a small cluster of DGX Sparks, and one
ordinary computer to drive them.

```
   ┌─────────────────────────┐
   │  WORKSTATION / laptop   │   no GPU needed
   │  - renders frames       │   ~250 MB of data
   │  - serves /display      │   holds the repo
   │  - drives the cluster   │
   └───────────┬─────────────┘
               │  SSH (key-based)
   ┌───────────┼───────────┬───────────────┐
   │           │           │               │
┌──▼───┐   ┌───▼──┐   ┌────▼───┐      ┌────▼────────┐
│Spark1│   │Spark2│   │ Spark3 │      │ big screen  │
│member│   │member│   │agent   │      │ browser ->  │
│  s   │   │  s   │   │ LLM    │      │ /display    │
└──────┘   └──────┘   └────────┘      └─────────────┘
  ~57 GB     ~56 GB      ~98 GB
```

| | runs | needs |
|---|---|---|
| **DGX Sparks** (1+) | SFNO forecasts, CorrDiff downscaling, the agent's LLM | GB10, ~80 GB free disk each |
| **Workstation** | frame rendering, the web UI, cluster control | **no GPU, no CUDA, no Docker** |

**The workstation is not optional, but it is not special either.** It holds
about 250 MB (2 MB of code + collected data + rendered frames) against roughly
210 GB on the Sparks. All the heavy lifting — every forecast, all 289M-parameter
SFNO inference, the 30B language model — happens on the GB10s. The workstation
is a remote control: it issues commands over SSH and turns the returned numpy
arrays into pictures.

A laptop is genuinely sufficient. Setup: **[docs/WORKSTATION.md](docs/WORKSTATION.md)**.

If you are short on hardware, one Spark can play both roles — see
[hosting the controller on a Spark](docs/WORKSTATION.md#limited-hardware-hosting-the-controller-on-a-spark),
including what you give up.

### Node roles

The Spark hosting the agent's LLM has ~15 GB of its 128 GB unified memory free,
and an SFNO ensemble member needs 16 GB — so `scripts/ensemble.sh` **skips it**
and splits members across the nodes that can hold them. This is reported by
`./demo status`, never silent. Stop the LLM and that node rejoins the pool
automatically.

Because the check runs at launch, **start the agent before the ensemble** — or
just re-run `ensemble.sh` afterwards to rebalance. See
[If you are also running the agent](#if-you-are-also-running-the-agent-set-it-up-first).

## Scaling: adding or removing a Spark

**Yes — a new Spark with key-based SSH from the workstation is the whole job.**
Nothing in the scripts hardcodes a node count or an address; the roster lives
in one line of `cluster.conf`.

```bash
ssh-copy-id nvidia@<new-spark>              # 1. key-based SSH
$EDITOR cluster.conf                        # 2. append to NODES="..."
./scripts/preflight.sh                       # 3. verify it is ready
./scripts/distribute.sh                      # 4. copy + load the image (~4 min)
./scripts/fetch-models.sh                    # 5. stage SFNO weights (or copy ~/e2cache)
./demo check                                 # 6. confirm
```

Step 4 needs no internet — it streams the image tarball from the build node
over the LAN. Step 5 needs internet **or** a copy of `~/e2cache` from an
existing node.

What adapts automatically:

- **Member scheduling** — round-robin across every node with enough free memory
- **Member count** — rounded down to divide evenly across usable nodes, so you
  never get a silently partial ensemble
- **The display's CLUSTER card** — rendered from the roster and the run's
  actual assignment, so a fourth Spark appears on the booth screen with no
  code change
- **`./demo status`** — reports every node and why any is being skipped

Removing a node is the reverse: drop it from `NODES`. Nothing else references it.

**Sizing guidance.** Ensemble members are independent, so this scales linearly
and cleanly: ~7 concurrent members fit per Spark (16 GB each of 128 GB), and
more nodes means more members at the same wall-clock time, not faster members.
Two forecasting Sparks comfortably run the 6-member demo; a fourth is worth
adding if you want a larger ensemble on screen, not to make the existing one
quicker.

## At the booth

```bash
./demo check      # night before -- full readiness check
./demo start      # doors open
./demo status     # what is running, what is not
./demo stop       # doors close
```

Full show-floor runbook, including the USB-stick install and the failure
playbook: **[docs/SHOW_FLOOR.md](docs/SHOW_FLOOR.md)**.

## Quick start

```bash
git clone https://github.com/nv-drollins/earth2-spark-ensemble.git
cd earth2-spark-ensemble

cp cluster.conf.example cluster.conf
$EDITOR cluster.conf          # set NODES to your SSH targets

./scripts/preflight.sh        # check every node BEFORE downloading 48 GB
./scripts/build.sh            # build once on node 1, export the tarball
./scripts/distribute.sh       # copy + load onto the rest
./scripts/fetch-models.sh     # pre-stage SFNO weights -- DO THIS WHILE ONLINE
./scripts/verify.sh           # runtime SFNO + CUDA smoke test on every node

MEMBERS=6 STEPS=20 ./scripts/ensemble.sh
```

All scripts are idempotent -- re-running skips work that is already done.

### If you are also running the agent, set it up FIRST

`ensemble.sh` decides where members go by probing **free memory at launch**,
skipping any node with less than `E2_MIN_FREE_GB` (default 24 GB) because one
SFNO member needs 16 GB. The agent's ~30B vLLM leaves its host with ~15 GB
free, so that node drops out and the members rebalance onto the rest.

Order matters:

```bash
E2_AGENT_NODE=user@spark-3 ./agent/setup-agent.sh   # loads vLLM, ~4-6 min
MEMBERS=6 STEPS=20 ./scripts/ensemble.sh            # now 3 + 3 on two nodes
```

Run the ensemble first and all three nodes are still idle, so you get 2+2+2 --
then the agent node is hosting both an LLM and two members. **Just re-run
`ensemble.sh` after the LLM is up**; it re-probes every time, clears stale
member output on every node (including skipped ones), and rebalances. Nothing
to move by hand.

`./demo status` names the skipped node and the free-memory reason, so a node
contributing zero members reads as intended rather than broken.

> Do **not** set `E2_MIN_FREE_GB=0` to force a member onto the agent node. It
> OOMs with `CUDA error: out of memory`, and since members run in parallel that
> failure is easy to miss among the successes.

### Going to a venue with no internet

`build.sh` + `fetch-models.sh` are the only steps needing connectivity. Run
both at the office, then carry `$BUNDLE_DIR` (tarball) and `$CACHE_DIR`
(weights) on a USB stick. On site: `distribute.sh` and `verify.sh` only.

---

## Configuration

Everything site-specific lives in `cluster.conf`, which is **gitignored**. No
hostnames, IPs, or paths are hardcoded anywhere in the scripts.

```bash
NODES="user@spark-1 user@spark-2 user@spark-3"   # first entry = build node
IMAGE="earth2-spark:1.0"
BUNDLE_DIR="$HOME/e2dist"
CACHE_DIR="$HOME/e2cache"
BASE_IMAGE="nvcr.io/nvidia/physicsnemo/physicsnemo:26.08"
E2S_VERSION="0.18.0"
MAKANI_REF="main"
TH_REF="v0.9.2"
```

---

## Layout

```
docker/Dockerfile        the verified build recipe, heavily commented
cluster.conf.example     site config template (copy to cluster.conf)
scripts/
  common.sh              shared helpers, config loading, sudo/docker probing
  preflight.sh           per-node readiness checks (read-only)
  build.sh               build once on the build node, export tarball
  distribute.sh          copy + load the image onto every node
  fetch-models.sh        pre-stage SFNO weights into the cache
  verify.sh              runtime SFNO + CUDA verification
  ensemble.sh            fan N members across the cluster
ensemble/run_member.py   single ensemble member (runs inside the container)
docs/PITFALLS.md         10 traps hit building this, with symptoms and fixes
```

---

## Before you change the Dockerfile

Read [docs/PITFALLS.md](docs/PITFALLS.md). The pinned versions are not
arbitrary -- there is a genuine three-way version deadlock between makani,
PhysicsNeMo, and torch-harmonics that forces several unusual choices:

- `earth2studio[sfno]` from PyPI **silently downgrades** 0.18.0 -> 0.5.0
- makani `main` is required, **not** its newest release tag `v0.2.1`
- torch-harmonics must come from **GitHub**, not PyPI
- `--no-build-isolation` is mandatory for torch-harmonics
- SFNO **cannot** be imported during `docker build` (no `libcuda.so.1`)

---

## Booth demo (presentation layer)

Runs on the **workstation driving the booth monitor** &mdash; NOT on a Spark
node. No GPU needed: rendering is pure numpy + PIL.

```bash
pip install -r viz/requirements.txt   # workstation only, one time
./scripts/collect.sh                  # pull member output back from the nodes
python3 viz/render.py                 # render globe frames + spread maps
./viz/start-display.sh                # start the server, prints its URLs
```

`start-display.sh` is idempotent (re-running just reports the existing server),
checks its dependencies, warns if no frames are rendered yet, and prints the
LAN URLs to open. `./viz/stop-display.sh` stops it.

Override with `E2_PORT` / `E2_HOST` / `E2_FRAMES` if needed.

- **`/display`** &mdash; aisle-facing. Globes, spread map, chaos curve. No controls, nothing blinks.
- **`/operator`** &mdash; presenter-facing. Story beats, divergence playback, "run new ensemble".

The display serves **pre-rendered frames**, so a cluster hiccup mid-conversation
never blanks the booth screen. `Run new ensemble` on the operator page does real
compute on the Sparks, then re-collects and re-renders.

### The story it tells

Ensemble spread in 2 m temperature, measured on GB10:

| lead | mean spread | max spread |
|---|---|---|
| 0 h | **0.0004 K** | 0.00 K |
| 24 h | 5.80 K | 28.08 K |
| 48 h | **7.83 K** | 41.39 K |

Six members start effectively identical and fan out monotonically. That curve is
chaos theory, measured live, in about 30 seconds &mdash; and the spread map shows
*where* the forecast doesn't know.

Full booth script, audience-by-audience pivots, and the hard questions with
honest answers: **[docs/DEMO_NARRATIVE.md](docs/DEMO_NARRATIVE.md)**.

---

## License

The scripts and documentation in this repository are provided as-is.
The NGC base image, PhysicsNeMo, Earth2Studio, makani, and the SFNO model
weights are governed by their own NVIDIA licenses.
