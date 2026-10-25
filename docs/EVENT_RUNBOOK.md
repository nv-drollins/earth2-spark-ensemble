# Event Runbook — Earth-2 Spark Ensemble

Step-by-step, start to finish, for taking this demo to a venue on **three
Sparks you have never used before** plus a control laptop.

Every command says **which machine it runs on**. That is the single most
confusing thing about this repo, so it is marked on every step.

- **[LAPTOP]** — the control machine. No GPU, no CUDA, no Docker.
- **[SPARK-n]** — one of the three GB10 nodes. You rarely log in directly.
- **[OFFICE]** — do this before you travel, while you have internet.

---

## Why there is a laptop at all

The Sparks compute. They never draw anything.

The booth display (`/display` on the big screen, `/operator` on your laptop) is
served by `viz/server.py` running **on the laptop**, from frames that
`render.py` writes **on the laptop**. The frames are pre-rendered, which is
what makes the booth survivable: if a Spark drops mid-conversation, the globes,
the spread map, the scrub control and the downscaling panel all keep working.
Only a live re-run is lost.

Serve the UI from a Spark instead and a single node hiccup blanks the screen in
front of a visitor.

---

## Timeline for this event

| when | where | what |
|---|---|---|
| **now → Nov 4** | office | build, stage, USB copy, laptop prep (Parts 1) |
| **Nov 5, setup day** | venue, has wifi | Parts 2–4: network, SSH, load the Sparks, install the agent |
| **Nov 5, afternoon** | venue | re-stage a fresh IC (`2026-11-04`), run the chain, leave it running |
| **Nov 6, show day** | venue | `./demo start`, `./demo status`, open the two browser windows |

Being on site a day early is what makes Plan A viable: a fresh forecast
spanning show day, with a two-week-old fallback already on the stick if the
wifi disappoints.

---

## PART 1 — At the office (before you travel)

Everything expensive happens here. It is all machine-independent: an image
tarball and model weights load onto *any* GB10, so none of this has to be
redone for the new Sparks.

### 1.1 [OFFICE] Build and stage

Done from a machine that can reach three Sparks with internet. Already
completed for this event; listed so the sequence is on record.

- `./scripts/preflight.sh` — per-node readiness, **before** pulling 48 GB
- `./scripts/build.sh` — builds on the FIRST node in `NODES`, exports one tarball
- `./scripts/distribute.sh` — loads the image onto the other nodes
- `./scripts/verify.sh` — **runtime** SFNO + CUDA check. Do not skip: the image
  can build perfectly and still fail to load SFNO (see Pitfall 1 below)
- `./scripts/stage-offline.sh --with-agent --date <YYYY-MM-DD>` — SFNO
  weights, CorrDiff weights, initial conditions, and the agent's LLM

### 1.2 [OFFICE] Copy four things onto a USB stick

| from | to the stick as | size |
|---|---|---|
| `<build-node>:~/e2dist/earth2-spark_1.1.tar.zst` | `e2dist/` | **15 GB** |
| `<any-node>:~/e2cache/` | `e2cache/` | **~8 GB** |
| `<agent-node>:~/.cache/huggingface/` | `hf-cache/` | **~30 GB** |
| the repo itself (`git clone` or a zip) | `earth2-spark-ensemble/` | ~1 MB |

```bash
# [OFFICE]
rsync -a --info=progress2 e2-spark-1:~/e2dist/  /media/usb/e2dist/
rsync -a --info=progress2 e2-spark-1:~/e2cache/ /media/usb/e2cache/
rsync -a --info=progress2 e2-spark-3:~/.cache/huggingface/ /media/usb/hf-cache/
```

Use a **USB 3.x stick with ≥64 GB free**. On USB 2 this copy takes hours.

### 1.3 [OFFICE] Prepare the laptop

Do this before you travel — it is the step that fails at the worst moment if
left to the venue, because Ubuntu 24.04+ blocks system-wide `pip` (PEP 668) and
the error message tells you to do the thing that cannot work.

```bash
# [LAPTOP]
git clone https://github.com/nv-drollins/earth2-spark-ensemble.git
cd earth2-spark-ensemble
python3 -m venv .venv
.venv/bin/pip install -r viz/requirements.txt
.venv/bin/python -c "import fastapi, uvicorn, jinja2, PIL, numpy; print('viz deps OK')"
```

Also generate an SSH key if the laptop has none — you will need it on site:

```bash
# [LAPTOP]
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
```

---

## PART 2 — On site: network and SSH

This is the only genuinely site-specific work, and it is small by design.

### 2.1 [LAPTOP] Find the Sparks' addresses

Power on all three Sparks. Then, from the laptop:

```bash
# [LAPTOP] — try mDNS first; each Spark answers to its own hostname.local
getent hosts spark-XXXX.local

# if mDNS is blocked on the venue network, scan your subnet instead
ip -4 -br addr                      # find your own subnet first
nmap -sn 192.168.1.0/24 | grep -B2 -i nvidia
```

Get each Spark's hostname from its own desktop (`hostname` in a terminal) if
you are unsure which is which.

### 2.2 [LAPTOP] Write the SSH config — the ONLY file with site details

```bash
# [LAPTOP]
cat >> ~/.ssh/config <<'EOF'
Host e2-spark-1
    HostName 192.168.1.11      # <-- CHANGE: Spark 1's address or .local name
    User nvidia

Host e2-spark-2
    HostName 192.168.1.12      # <-- CHANGE
    User nvidia

Host e2-spark-3
    HostName 192.168.1.13      # <-- CHANGE: this one hosts the agent LLM
    User nvidia

Host e2-spark-*
    BatchMode yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 4
EOF
chmod 600 ~/.ssh/config
```

**`cluster.conf` never changes.** It refers to `e2-spark-1/2/3`, and those
aliases are resolved here. Three `HostName` lines are your entire site config.

### 2.3 [LAPTOP] Push your SSH key to each Spark

```bash
# [LAPTOP] — asks for each Spark's password once
ssh-copy-id -o StrictHostKeyChecking=accept-new nvidia@<spark-1-address>
ssh-copy-id -o StrictHostKeyChecking=accept-new nvidia@<spark-2-address>
ssh-copy-id -o StrictHostKeyChecking=accept-new nvidia@<spark-3-address>

# verify all three answer without a password
for n in e2-spark-1 e2-spark-2 e2-spark-3; do echo -n "$n -> "; ssh $n hostname; done
```

### 2.4 [LAPTOP] Create cluster.conf

```bash
# [LAPTOP]
cd ~/earth2-spark-ensemble
cp cluster.conf.example cluster.conf
```

Then edit `cluster.conf` so it reads exactly:

```bash
NODES="e2-spark-1 e2-spark-2 e2-spark-3"
IMAGE="earth2-spark:1.1"
BUNDLE_DIR="$HOME/e2dist"
CACHE_DIR="$HOME/e2cache"
BASE_IMAGE="nvcr.io/nvidia/physicsnemo/physicsnemo:26.08"
E2S_VERSION="0.18.0"
MAKANI_REF="01c7776f68b72809939ba3c30c3eb0adecfc4922"
TH_REF="v0.9.2"
```

`IMAGE` **must** match the tarball you carried (`1.1`, not `1.0`). A mismatch
breaks only the steps that start a fresh container, so it surfaces later as a
confusing failure in whichever script you happen to run next.

### 2.5 [LAPTOP] Preflight

```bash
# [LAPTOP]
./scripts/preflight.sh
```

Expect `OK` on SSH, aarch64, GPU, docker, NVIDIA runtime, ≥80 GB disk, memory,
zstd for all three. **Fix anything red before continuing.**

If a Spark says *"docker present but user is not in the 'docker' group"*:

```bash
# [SPARK-n] — run on that Spark, then log out and back in
sudo usermod -aG docker $USER
```

---

## PART 3 — On site: load the demo onto the new Sparks

No internet needed for any of this.

### 3.1 [LAPTOP] Copy the image tarball to Spark 1

**`distribute.sh` cannot start without this.** It streams the tarball *from the
build node* — which, on new hardware, is whichever Spark you put the tarball on.
With no tarball present it exits immediately with `bundle missing`.

```bash
# [LAPTOP] — with the USB stick mounted
ssh e2-spark-1 'mkdir -p ~/e2dist'
rsync -a --info=progress2 /media/usb/e2dist/ e2-spark-1:~/e2dist/
```

### 3.2 [LAPTOP] Distribute the image to all three

```bash
# [LAPTOP]
./scripts/distribute.sh        # ~4 min/node
```

It loads on Spark 1 and streams to Sparks 2 and 3 over the LAN — no
node-to-node SSH keys required.

### 3.3 [LAPTOP] Copy the model weights to every Spark

Every node needs its own copy; a node without weights cannot run a member.

```bash
# [LAPTOP]
for n in e2-spark-1 e2-spark-2 e2-spark-3; do
  ssh $n 'mkdir -p ~/e2cache'
  rsync -a --info=progress2 /media/usb/e2cache/ $n:~/e2cache/
done
```

### 3.4 [LAPTOP] Copy the LLM weights to Spark 3 only

Skip if you are running forecast-only.

```bash
# [LAPTOP]
ssh e2-spark-3 'mkdir -p ~/.cache/huggingface'
rsync -a --info=progress2 /media/usb/hf-cache/ e2-spark-3:~/.cache/huggingface/
```

### 3.5 [LAPTOP] Verify everything landed

```bash
# [LAPTOP]
./scripts/stage-offline.sh --verify --date 2026-10-23      # checksums, no downloads
./scripts/verify.sh                                        # real SFNO load on each node
```

`verify.sh` must print `VERIFY_OK` three times. This runs SFNO for real on each
GPU and is the only check that catches a broken model stack.

---

## PART 4 — On site: install the agent (Spark 3)

Skip entirely for a forecast-only show.

### 4.1 [SPARK-3] Install NemoClaw

Needs internet **once** — the venue wifi on setup day (Nov 5) covers this.
If wifi turns out to be unusable, this is the one part of the demo that
cannot be installed on site; you would run forecast-only. Doing it at the
office on the new Sparks beforehand removes that risk entirely.

```bash
# [SPARK-3]
curl -fsSL https://www.nvidia.com/nemoclaw.sh | \
  NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 NEMOCLAW_SANDBOX_NAME=throwaway-init bash
```

It **ends with an error** — `vLLM install failed: port 8000 is already in use`
— and exits non-zero. **That is expected and harmless.** The CLIs installed
fine. Confirm and clean up its throwaway sandbox:

```bash
# [SPARK-3]
nemoclaw --version
~/.local/bin/nemoclaw throwaway-init destroy --yes
docker rm -f nemoclaw-vllm 2>/dev/null
```

Use the **absolute path** for the destroy — `nemoclaw` lives in `~/.local/bin`,
which only joins `PATH` via `~/.profile` (a login shell).

### 4.2 [LAPTOP] Serve the model and onboard the sandbox

```bash
# [LAPTOP]
E2_AGENT_NODE=e2-spark-3 ./agent/serve-model.sh    # 4-6 min to load
ssh e2-spark-3 'curl -s localhost:8000/v1/models'  # confirm WHAT is served
E2_AGENT_NODE=e2-spark-3 ./agent/setup-agent.sh
```

Check the model id actually reported — a container that is "Up" can still be
crash-looping with an older model still answering.

---

## PART 5 — Produce the display

This is the part most easily left half-done: an ensemble writes `.npy` **on the
Sparks**, and nothing reaches the screen until you collect and render.

### 5.0 First, pick the IC date

The **IC (initial-condition) date is not the event date** — it is where the
forecast *starts*. SFNO initialises from that analysis and rolls forward 5
days, so the screen shows `IC` through `IC + 5 days`.

| | date | what the booth shows |
|---|---|---|
| **Plan A — re-stage on site** | IC `2026-11-04` | forecast for Nov 4–9, spanning show day |
| **Plan B — fallback on the stick** | IC `2026-10-23` | a correct but two-week-old forecast |

Use an IC **two days before the day you stage it**. GFS analyses take hours to
publish, which is why `ensemble.sh` itself defaults to "two days ago". Asking
for today's date gets you a fetch failure.

**Plan A — Nov 5, setup day, on venue wifi:**

```bash
# [LAPTOP]
./scripts/stage-offline.sh --date 2026-11-04     # ~2 GB, forecast only
./scripts/stage-offline.sh --verify --date 2026-11-04
```

Then use `DATE=2026-11-04` in every command below.

**Plan B — no usable wifi.** Do nothing: the staged IC is already on the
Sparks. Use `DATE=2026-10-23`. The demo is identical apart from the dates on
screen. (That IC also stays fetchable from GFS until roughly Nov 20.)

Whichever you use, **pin it on both `ensemble.sh` and `corrdiff.sh`** — both
default to "two days ago", which at the venue is a date you never staged.

### 5.1 Run the chain

```bash
# [LAPTOP] — all five, in this order
DATE=<IC-DATE> MEMBERS=6 STEPS=20 ./scripts/ensemble.sh   # ~3-5 min
DATE=<IC-DATE> ./scripts/corrdiff.sh                      # ~30 s
./scripts/collect.sh                                      # Sparks -> ~/e2viz/data
.venv/bin/python viz/render.py                            # data -> ~/e2viz/frames
./demo start                                              # serve /display + /operator
```

**Use `.venv/bin/python`, never bare `python3`** — numpy and pillow are not in
system Python.

**Pin `DATE` on both `ensemble.sh` and `corrdiff.sh`.** Both default to "two
days ago", which will be a date you never staged; with no internet they fail.
When a staged IC is found, `ensemble.sh` prints `using staged IC for <date>
(offline)`.

**`corrdiff.sh` is a separate run and is the easiest step to skip.** It
produces the only rainfall variable in the demo. Omit it and the globes work
while the downscaling panel is silently absent — no error names the cause.

Then open:
- **`/display`** on the aisle screen, fullscreen (F11)
- **`/operator`** on your laptop

`./demo status` reprints both URLs.

---

## PART 6 — Daily booth routine

**Morning (~10 min before doors):**

```bash
# [LAPTOP]
./demo start      # returns immediately; LLM loads in the background
./demo status     # confirm all green
```

The globes work the whole time the LLM is loading. Only the Ask/Plan panel waits.

**Evening:**

```bash
# [LAPTOP]
./demo stop       # leaves the LLM running on purpose -- 5 min to reload
```

**Pack-down:**

```bash
# [LAPTOP]
./demo shutdown   # stops the display and every container on every node
```

Rendered frames survive a reboot. Next morning `./demo start` is all you need.

---

## Pitfalls that will cost you the show

**1. A green build does NOT mean a working model.**
The image can build perfectly, CorrDiff can work, and SFNO still fail at
runtime. It happened during prep for this event: makani `main` picked up commit
`79a838d2` (2026-10-12), which discontinued the `add_orography` /
`add_landmask` options the published SFNO checkpoint still sets —
`ValueError: The options [...] are discontinued`. Hence the pinned
`MAKANI_REF`. **Never skip `verify.sh`, and never rebuild at a venue.**

**2. Do not re-run `build.sh` on site.** It needs internet, takes ~15 minutes,
and pulls whatever upstream looks like *that day* — which is exactly how
pitfall 1 arrives.

**3. `distribute.sh` skips any node that already has `$IMAGE`.** Changing the
image contents without changing the tag leaves stale images in place silently.
Bump the tag.

**4. The agent node runs ZERO ensemble members, by design.** Spark 3 hosts the
~30B LLM, leaving ~15 GB free of 128 GB; a member needs 16 GB. Members split
3+3 across Sparks 1 and 2. `./demo status` reports this. It is correct, not
broken.

**5. Start the agent BEFORE the ensemble.** Placement is decided at launch by
probing free memory. Wrong order? Just re-run `ensemble.sh` — it re-probes,
clears stale output everywhere, and rebalances. Then re-run `collect.sh` and
`render.py`.

**6. Never set `E2_MIN_FREE_GB=0`** to force a member onto the agent node. It
OOMs, and parallel members bury the failure.

**7. Re-run `collect.sh` + `render.py` after EVERY new ensemble.** The display
serves frames from disk; without a re-render you are showing the previous run.

---

## Quick reference

| I want to… | command | machine |
|---|---|---|
| check everything is ready | `./demo check` | LAPTOP |
| see what is running | `./demo status` | LAPTOP |
| bring the booth up | `./demo start` | LAPTOP |
| new forecast on screen | `ensemble.sh` → `corrdiff.sh` → `collect.sh` → `render.py` | LAPTOP |
| display only, no cluster | `./viz/start-display.sh` | LAPTOP |
| shut down for the night | `./demo stop` | LAPTOP |
| pack down | `./demo shutdown` | LAPTOP |
