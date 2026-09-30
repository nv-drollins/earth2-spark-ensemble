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
