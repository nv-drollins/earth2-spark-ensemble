# INSTALL — Earth-2 Spark Ensemble, from bare metal

One guide, used twice: the wipe-and-rebuild rehearsal, and the venue.
Follow it top to bottom. Every command says which machine it runs on.

- **[LAPTOP]** — the control machine (WSL2 Ubuntu). No GPU, no CUDA, no Docker.
- **[SPARK-n]** — a GB10 node. You log in directly only in Stage 2.

**Time:** ~60–75 min for three Sparks, mostly file copying.

---

## What you need before you start

| item | where it is | size |
|---|---|---|
| `e2dist/` — image tarball | USB stick | **15 GB** |
| `e2cache/` — SFNO + CorrDiff weights + IC | USB stick | **8.5 GB** |
| `hf-cache/` — agent LLM | USB stick | **21 GB** |
| the repo | `github.com/nv-drollins/earth2-spark-ensemble` | ~1 MB |

Total **~45 GB**. Use a USB 3.x stick with ≥64 GB free.

**The bundle is the only irreplaceable thing you carry.** Rebuilding it needs
internet and ~90 minutes. Never wipe every machine that holds it without a copy
elsewhere first.

### Choosing the USB drive — two traps that waste an hour each

| requirement | why |
|---|---|
| **NOT FAT32** | FAT32 caps a single file at **4 GB**. The image tarball is 15 GB, so a FAT32 stick CANNOT hold it — by any method. Use NTFS or exFAT. |
| **USB 3 port** | Measured on the same workstation: USB 2 (480 Mbit/s) ~40 MB/s vs USB 3 (5000 Mbit/s). 45 GB is ~20 min vs ~5 min. Check with `lsusb -t`. |

**A GUI copy that sits at 99% is usually not hung.** Linux accepts writes into
page cache, so the progress bar finishes long before the drive does —
`grep Dirty /proc/meminfo` showed **18.9 GB still unwritten** while a desktop
copy looked complete. Use `scripts/copy-bundle-to-usb.sh`, which reports real
throughput and calls `sync` before declaring success.

```bash
# [WORKSTATION] writes the bundle and verifies checksums
./scripts/copy-bundle-to-usb.sh /media/<user>/<LABEL>
```

It refuses FAT32 up front, packs the symlinked LLM cache into a tar, and
verifies file counts, byte totals and a sha256 of the 15 GB tarball.

---

## Stage 0 — [LAPTOP] Check your kit before touching the Sparks

### Where the bundle lives — do NOT copy it into WSL

On a Windows + WSL2 laptop, leave the bundle **on the Windows drive**. WSL
reads it directly through `/mnt/c`, so copying it into the Linux filesystem
burns 45 GB and an hour for no benefit.

| Windows path | the same thing from WSL |
|---|---|
| `C:\demos\earth2\e2bundle` | `/mnt/c/demos/earth2/e2bundle` |

Every command in this guide uses that literal path. **If yours differs, the
only thing to change is the `/mnt/c/...` part** — the right-hand side of each
`rsync` (`node:~/...`) is the SPARK's home directory and must not change.

> **Reading an `rsync` line:** everything left of the colon is your laptop,
> everything after `node:` is the Spark. `~/e2cache` on the right means
> `/home/<spark-user>/e2cache` on that Spark, not a path on your laptop.

> **Windows->Linux does not add junk files here.** `:Zone.Identifier` streams
> are NTFS metadata on downloaded files; `rsync` copies contents and ignores
> them, and a Linux-produced bundle has none. The one real cross-filesystem
> problem is **symlinks**, which is why the LLM cache ships as a tar (3.4).
> `e2dist` and `e2cache` contain zero symlinks — verified.

### Check everything is present

```bash
ls -lh /mnt/c/demos/earth2/e2bundle/e2dist/*.tar.zst     # ~15 GB tarball
du -sh /mnt/c/demos/earth2/e2bundle/e2cache              # ~8.5 GB
du -sh /mnt/c/demos/earth2/e2bundle/hf-cache.tar         # ~21 GB
tar -tf /mnt/c/demos/earth2/e2bundle/hf-cache.tar | wc -l   # ~415 = readable
cd ~/earth2-spark-ensemble && git pull
.venv/bin/python -c "import fastapi,uvicorn,jinja2,PIL,numpy; print('viz deps OK')"
```

### The IC date for THIS bundle: `2026-10-23`

The bundle carries pre-fetched initial conditions for one date. Wherever this
guide says `<IC-DATE>`, use **`2026-10-23`**.

It is the date the forecast STARTS from, not today's date and not the event
date. To confirm what your bundle actually holds:

```bash
ls /mnt/c/demos/earth2/e2bundle/e2cache/ic/        # ic_<DATE>.nc
```

### What each Spark needs before you start (Stage 1 does this)

Per Spark, three things — all covered in Stage 1, listed here so you can see
the whole shape first:

| | why |
|---|---|
| `sudo usermod -aG docker $USER` **+ log out/in** | scripts refuse to run docker via password-sudo |
| `sudo nvidia-ctk runtime configure --runtime=docker` **+ restart docker** | DGX OS ships the toolkit INSTALLED BUT NOT CONFIGURED; without it every `--gpus all` container fails |
| `sudo apt install -y zstd openssh-server` | `zstd` unpacks the image bundle |

## Stage 1 — [SPARK-n] Bring each Spark up after the wipe

Do this on **each** Spark, at its own keyboard or over the vendor's recovery
path. Three things only.

### 1.1 Confirm the basics

```bash
uname -m                 # aarch64
nvidia-smi               # driver + GB10 visible
lsb_release -ds          # Ubuntu 24.04
hostname                 # WRITE THIS DOWN -- you need it in Stage 2
```

### 1.2 Put the login user in the `docker` group

```bash
sudo usermod -aG docker $USER
```

**Then log out and back in.** The group does not apply to your current shell.
Verify — this must work with no `sudo`:

```bash
docker run --rm hello-world
```

### 1.3 Configure the NVIDIA Container Toolkit

DGX OS ships the toolkit **installed but NOT configured** — Docker does not
know about the `nvidia` runtime until you register it. Every bit of compute in
this demo runs with `--gpus all`, so without this step SFNO fails at load time
with:

```
OSError: libcuda.so.1: cannot open shared object file
```

which reads as a broken image rather than a missing runtime hook.

```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Verify Docker now lists it:

```bash
docker info | grep -i runtimes        # must include 'nvidia'
```

Then prove it end to end — this is the check that matters, because it
exercises the hook that injects `libcuda.so.1`:

```bash
docker run --rm --gpus all nvcr.io/nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi
```

It must print the GB10 table. If it fails with `could not select device driver`,
the runtime is still not registered — re-run `nvidia-ctk` and restart Docker.

> If `nvidia-ctk` is missing entirely (not the case on stock DGX OS):
> `sudo apt install -y nvidia-container-toolkit`

### 1.4 Install `zstd` and `openssh-server`

```bash
sudo apt update
sudo apt install -y zstd openssh-server
sudo systemctl enable --now ssh
```

`zstd` unpacks the image bundle; without it `distribute.sh` fails at the last
step after copying 15 GB.

### 1.5 Note the address

```bash
ip -4 -br addr | grep -v '^lo'
```

Write down each Spark's IP (or confirm `<hostname>.local` resolves — if you
brought your own switch, mDNS usually just works).

---

## Stage 2 — [LAPTOP] Network and SSH

This is the only genuinely site-specific work.

### 2.1 Clear stale host keys FIRST (only when reinstalling)

A wiped Spark generates a new SSH host key. If this laptop has talked to that
address before, the first connection aborts with:

```
WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
Someone could be eavesdropping on you right now (man-in-the-middle attack!)
```

That is expected after a reinstall, not an attack — and `ssh-copy-id` refuses
to run until it is cleared. Do this for every address you are reusing:

```bash
ssh-keygen -R <spark-1-addr>
ssh-keygen -R <spark-2-addr>
ssh-keygen -R <spark-3-addr>
```

Skip this at a venue with brand-new addresses — there is nothing cached to clear.

### 2.2 Push your key to all three

```bash
ssh-copy-id -o StrictHostKeyChecking=accept-new <user>@<spark-1-addr>
ssh-copy-id -o StrictHostKeyChecking=accept-new <user>@<spark-2-addr>
ssh-copy-id -o StrictHostKeyChecking=accept-new <user>@<spark-3-addr>
```

Each asks for that Spark's password once. If you have no key yet:
`ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519`

### 2.3 Write the aliases — THE ONLY FILE WITH SITE DETAILS

```bash
cat >> ~/.ssh/config <<'EOF'

Host e2-spark-1
    HostName CHANGE-ME-1
    User CHANGE-ME-USER

Host e2-spark-2
    HostName CHANGE-ME-2
    User CHANGE-ME-USER

Host e2-spark-3
    HostName CHANGE-ME-3
    User CHANGE-ME-USER

Host e2-spark-*
    BatchMode yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 4
EOF
chmod 600 ~/.ssh/config
$EDITOR ~/.ssh/config      # replace the CHANGE-ME values
```

Verify all three answer **with no password prompt**:

```bash
for n in e2-spark-1 e2-spark-2 e2-spark-3; do printf "%-11s -> " $n; ssh $n hostname; done
```

> The control machine's username does NOT have to match the Sparks'. The
> scripts resolve each node's `$HOME` over SSH. (This was a real bug — fixed in
> commit 8dc3f27 — so if you are running an older checkout, `git pull` first.)

### 2.4 Create `cluster.conf`

```bash
cd ~/earth2-spark-ensemble
cat > cluster.conf <<'EOF'
NODES="e2-spark-1 e2-spark-2 e2-spark-3"
IMAGE="earth2-spark:1.1"
BUNDLE_DIR="$HOME/e2dist"
CACHE_DIR="$HOME/e2cache"
BASE_IMAGE="nvcr.io/nvidia/physicsnemo/physicsnemo:26.08"
E2S_VERSION="0.18.0"
MAKANI_REF="01c7776f68b72809939ba3c30c3eb0adecfc4922"
TH_REF="v0.9.2"
EOF
```

Use single-quoted `<<'EOF'` exactly as shown so `$HOME` stays literal — it must
be expanded on each node, not here.

`NODES` uses **aliases**, so this file is byte-identical at the lab and the
venue. `IMAGE` **must** match the tarball you carried (`1.1`).

### 2.5 Preflight

```bash
./scripts/preflight.sh
```

All three must be green. Common failures:

| message | fix |
|---|---|
| `user is not in the 'docker' group` | Stage 1.2, then log out/in on that Spark |
| `NVIDIA container runtime not visible` | Stage 1.3 — toolkit installed but not configured |
| `zstd missing` | Stage 1.3 |
| `SSH failed` | Stage 2.2, or wrong `HostName` |
| `disk <80G free` | free space before continuing |

---

## Stage 3 — [LAPTOP] Load the demo onto the Sparks

No internet needed.

### Stage 3 has two paths — pick one

| | when to use it | ~45 GB takes |
|---|---|---|
| **A. USB at each Spark** (3.0 below) | the Sparks are physically reachable and you have `sudo` | **~8 min** |
| **B. Over the LAN** (3.1-3.4) | Sparks are racked/remote, or no `sudo` on them | ~25-35 min |

Path A is faster because `e2cache` otherwise crosses the LAN **three times**
(once per node) and `hf-cache` once more. It also removes the laptop as a
single point of failure during install. Path B is the fallback and is fully
supported — the two produce an identical result.

**They interoperate.** `distribute.sh` skips any node that already has the
image, so after Path A it just confirms all three are ready. You can also do
Path A on some nodes and Path B on the rest.

---

### 3.0 PATH A — load from USB at each Spark

Do this **on each Spark in turn**, with the stick plugged into that Spark.
Nothing here touches the network.

**Find the stick:**

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL          # look for your bundle drive
```

**DGX OS auto-mounts the stick** under `/media/<user>/<LABEL>` — check before
mounting anything yourself:

```bash
ls /media/$USER/                         # e.g. E2BUNDLE
USB=/media/$USER/E2BUNDLE                # adjust to YOUR label
ls $USB/e2bundle                         # sanity check: e2dist e2cache hf-cache.tar
```

Only if it did NOT auto-mount:

```bash
sudo mkdir -p /mnt/usb
sudo mount -t ntfs3 /dev/sda1 /mnt/usb   # use the device lsblk showed
USB=/mnt/usb
```

**1. Load the image** — straight off the stick, no network:

```bash
zstd -dc $USB/e2bundle/e2dist/earth2-spark_1.1.tar.zst | docker load
docker images | grep earth2              # expect earth2-spark:1.1
```

Expect ~1.5-3 min. Nearly all of that is `docker load` unpacking layers to
disk — **not** decompression and not the stick: measured on GB10, zstd runs at
~1.1 GB/s, so the whole 14.1 GiB stream decompresses in ~13 s. Storing the
image uncompressed would save those seconds and cost 34 GB more on the drive,
which is why it ships as `.tar.zst`.

**2. Model weights** (every Spark needs its own copy):

```bash
mkdir -p ~/e2cache
cp -r $USB/e2bundle/e2cache/* ~/e2cache/
du -sh ~/e2cache                         # expect ~8.5 GB
```

**3. Agent LLM — on the agent node ONLY** (skip for forecast-only):

```bash
mkdir -p ~/.cache/huggingface
tar -xf $USB/e2bundle/hf-cache.tar -C /tmp
cp -a /tmp/hf-cache/. ~/.cache/huggingface/
rm -rf /tmp/hf-cache
du -sh ~/.cache/huggingface              # expect ~21 GB
find ~/.cache/huggingface -type l | wc -l   # expect ~112 symlinks
```

Extract to `/tmp` (Linux), never onto the stick — NTFS cannot hold the
symlinks, which is the entire reason this ships as a tar. `/tmp` needs ~21 GB.

This tar is deliberately **uncompressed** (`tar -cf`, no `-z`): its payload is
already-compressed model weights, so compression would burn CPU on both ends
for almost no saving. It exists to preserve symlinks across a non-Unix
filesystem, nothing else.

**4. Before pulling the stick:**

```bash
sync
sudo umount $USB      # or eject from the desktop if it auto-mounted
```

**Then, once per cluster, from the LAPTOP:**

Confirm every node has it, then go straight to **3.5 Verify** — you can skip
3.1-3.4 entirely:

```bash
# [LAPTOP]
for n in e2-spark-1 e2-spark-2 e2-spark-3; do printf "%-11s " $n; ssh $n 'docker images --format "{{.Repository}}:{{.Tag}}" | grep earth2 || echo MISSING'; done
```

`./scripts/distribute.sh` is optional after this — it will report
`already has earth2-spark:1.1 -- skipping` three times and exit 0.

---

### 3.1 PATH B — copy the tarball to Spark 1 — DO THIS FIRST

`distribute.sh` streams the tarball **from the first node in `NODES`**. On
fresh hardware nothing is there yet, so without this it exits immediately with
`bundle missing on e2-spark-1`.

```bash
ssh e2-spark-1 'mkdir -p ~/e2dist'
rsync -a --info=progress2 /mnt/c/demos/earth2/e2bundle/e2dist/ e2-spark-1:~/e2dist/
```

### 3.2 Distribute the image

```bash
./scripts/distribute.sh        # ~4 min/node
```

Loads on Spark 1, streams to Sparks 2 and 3. No node-to-node SSH keys needed.

On Spark 1 you will see **`first node: loading from the tarball already on this
node`**. That is correct for a from-USB install: you copied the tarball in
(3.1) rather than building it here, so the image is not loaded yet and the
script loads it from the local file instead of streaming it from itself.
Older checkouts phrase this as `WARN build node lacks its own image` — same
behaviour, misleading wording.

Confirm all three ended up with it:

```bash
for n in e2-spark-1 e2-spark-2 e2-spark-3; do printf "%-11s " $n; ssh $n 'docker images --format "{{.Repository}}:{{.Tag}}" | grep earth2 || echo MISSING'; done
```

### 3.3 Weights to every Spark

```bash
for n in e2-spark-1 e2-spark-2 e2-spark-3; do
  ssh $n 'mkdir -p ~/e2cache'
  rsync -a --info=progress2 /mnt/c/demos/earth2/e2bundle/e2cache/ $n:~/e2cache/
done
```

Every node needs its own copy — a node without weights cannot run a member.

### 3.4 LLM weights to the agent node only

Skip for a forecast-only show.

The LLM cache ships as **`hf-cache.tar`**, not a plain directory. The
HuggingFace cache is built from symlinks (`snapshots/*.json` -> `../../blobs/<sha>`)
and **neither NTFS, exFAT nor FAT32 can store a Unix symlink** — a plain copy
fails with `symlink ... Operation not permitted` and leaves the model
unusable. The tar preserves them; Linux restores them on extract.

```bash
# [LAPTOP] -- extract to the LINUX filesystem, never onto /mnt/c or a USB drive:
# NTFS cannot hold the symlinks, which is the whole reason this is a tar.
tar -xf /mnt/c/demos/earth2/e2bundle/hf-cache.tar -C /tmp
ssh e2-spark-3 'mkdir -p ~/.cache/huggingface'
rsync -a --info=progress2 /tmp/hf-cache/ e2-spark-3:~/.cache/huggingface/
rm -rf /tmp/hf-cache
```

`/tmp` needs ~21 GB free (`df -h /tmp`). On WSL that is the VM's own disk,
which grows on demand.

Verify it landed as ~21 GB with symlinks intact:

```bash
ssh e2-spark-3 'du -sh ~/.cache/huggingface; find ~/.cache/huggingface -type l | wc -l'
```

### 3.5 Verify

```bash
./scripts/stage-offline.sh --verify --date 2026-10-23   # checksums only
./scripts/verify.sh                                     # real SFNO load per node
```

`verify.sh` must print **`VERIFY_OK` three times.** It actually loads SFNO on
each GPU and is the only check that catches a broken model stack. A clean
`docker load` proves nothing.

---

## Stage 4 — [LAPTOP+SPARK] The agent (skip for forecast-only)

### 4.1 [SPARK-3] Install NemoClaw — NEEDS INTERNET

```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | \
  NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 NEMOCLAW_SANDBOX_NAME=throwaway-init bash
```

It **ends with an error and exits non-zero**:
`vLLM install failed: port 8000 is already in use`. **That is expected.** The
CLIs installed fine. Confirm and clean up its throwaway sandbox:

```bash
nemoclaw --version
~/.local/bin/nemoclaw throwaway-init destroy --yes
docker rm -f nemoclaw-vllm 2>/dev/null
```

Use the **absolute path** — `nemoclaw` lives in `~/.local/bin`, which only
joins `PATH` in a login shell.

> Install it on **all three** Sparks if you can. The agent node is otherwise
> auto-detected as the first node that has `nemoclaw`, which may not be the one
> you intended.

### 4.2 [LAPTOP] Serve the model and onboard the sandbox

```bash
E2_AGENT_NODE=e2-spark-3 ./agent/serve-model.sh    # 4-6 min to load
ssh e2-spark-3 'curl -s localhost:8000/v1/models'  # confirm WHAT is served
E2_AGENT_NODE=e2-spark-3 ./agent/setup-agent.sh    # creates the sandbox
```

**`setup-agent.sh` is not optional.** `./demo start` starts the LLM and heals a
*broken* sandbox, but never creates one that does not exist. Without it, Plan
and Plan & Run fail with `planner did not return JSON`.

Confirm:

```bash
ssh e2-spark-3 'openshell sandbox list'     # e2-agent ... Ready
```

---

## Stage 5 — [LAPTOP] Produce the display

An ensemble writes `.npy` **on the Sparks**. Nothing reaches the screen until
you collect and render. All five steps, in order:

```bash
DATE=2026-10-23 MEMBERS=6 STEPS=20 ./scripts/ensemble.sh  # ~3-5 min
DATE=2026-10-23 ./scripts/corrdiff.sh                     # ~30 s
./scripts/collect.sh                                      # Sparks -> ~/e2viz/data
.venv/bin/python viz/render.py                            # -> ~/e2viz/frames
E2_AGENT_NODE=e2-spark-3 ./demo start                     # serve the UI
```

- **Pin `DATE` on BOTH `ensemble.sh` and `corrdiff.sh`.** Both default to "two
  days ago" — a date you never staged. With a staged IC present you will see
  `using staged IC for <date> (offline)`.
- **Use `.venv/bin/python`, never bare `python3`** — numpy and pillow are not
  in system Python.
- **`corrdiff.sh` is separate and the easiest step to skip.** It produces the
  only rainfall variable. Omit it and the globes work while the downscaling
  panel is silently absent, with no error.
- **Pin `E2_AGENT_NODE`** or the agent lands on whichever node answers first.

Then open:
- **`/display`** on the aisle screen, fullscreen (F11)
- **`/operator`** on your laptop

`./demo status` reprints both URLs.

---

## Stage 6 — [LAPTOP] Final gate

```bash
./demo check
```

Must show: preflight green, `VERIFY_OK` ×3, rendered frames present, display
serving, and **Agent readiness: sandbox 'e2-agent' Ready**.

That last line exists because a pre-show check once passed while Plan was
completely non-functional. If it says `NO sandbox`, go back to Stage 4.2.

---

## Fresh forecast on site (venue has internet)

```bash
./scripts/stage-offline.sh --date <two-days-ago>
DATE=<that-date> MEMBERS=6 STEPS=20 ./scripts/ensemble.sh
DATE=<that-date> ./scripts/corrdiff.sh
./scripts/collect.sh && .venv/bin/python viz/render.py
```

Use an IC **two days back** — GFS analyses take hours to publish. The staged IC
stays on disk as the fallback.

---

## Not used during install: the 200GbE fabric

Reasonable question, so it is answered here rather than rediscovered: the CX7
fabric is **not** used by any install step today, and wiring it in would be a
smaller win than it sounds.

Of the ~45 GB moved during an install, **most of it comes off the control
laptop** — the tarball to node 1, `e2cache` to all three, `hf-cache` to the
agent node. The laptop has no CX7, so those legs run at LAN speed no matter
what the Sparks have between them.

Only the node-to-node leg could use it, and `distribute.sh` deliberately does
not: it streams `build-node -> control-machine -> target`, which avoids
requiring node-to-node SSH keys that are usually absent on a fresh cluster.

Measured, if it were wired in: a 14 GB tarball is ~174 s over 1 GbE versus
~1 s over 200 GbE — roughly **8-10 minutes saved on a ~60 minute install**.

A larger restructure (copy everything to node 1 once, fan out over the fabric)
would help more, but it needs node-to-node keys, a reconfigured CX7 ring after
any wipe, and a change to `distribute.sh` — three new failure modes on the one
path that must not fail at a venue. It also assumes you cable the fabric at the
show, which is optional.

**The fabric changes nothing an attendee sees.** The ensemble is
embarrassingly parallel: each member is an independent `docker run` over SSH,
with no NCCL, no `torch.distributed`, no inter-node traffic during compute.
One member is a 37 MB `.npy`; collecting six moves ~224 MB.

## Pitfalls that cost a show

1. **Never rebuild at a venue.** `build.sh` needs internet and pulls whatever
   upstream looks like that day. An unpinned makani broke SFNO at runtime once
   already — the image built clean and only SFNO failed.
2. **A green build proves nothing.** Always `verify.sh`.
3. **`distribute.sh` skips nodes that already have `$IMAGE`.** Changing image
   contents without bumping the tag leaves stale images silently in place.
4. **The agent node runs ZERO ensemble members.** Hosting the ~30B LLM leaves
   ~15 GB free; a member needs 16 GB. Members split across the other two.
   `./demo status` reports it. Correct, not broken.
5. **Start the agent BEFORE the ensemble**, or re-run `ensemble.sh` after — it
   re-probes and rebalances. Then re-run `collect.sh` + `render.py`.
6. **Never set `E2_MIN_FREE_GB=0`** to force a member onto the agent node. It
   OOMs and parallel members bury the failure.
7. **Re-run `collect.sh` + `render.py` after EVERY ensemble**, or the display
   shows the previous run.
8. **The display survives the cluster.** Frames are pre-rendered — every Spark
   can go offline and the globes, spread map and scrub control keep working.
   `./viz/start-display.sh` alone needs no cluster at all.

---

## Quick reference

| I want to… | command | machine |
|---|---|---|
| check everything | `./demo check` | LAPTOP |
| what is running | `./demo status` | LAPTOP |
| bring the booth up | `E2_AGENT_NODE=e2-spark-3 ./demo start` | LAPTOP |
| new forecast | `ensemble.sh` → `corrdiff.sh` → `collect.sh` → `render.py` | LAPTOP |
| display only, no cluster | `./viz/start-display.sh` | LAPTOP |
| shut down for the night | `./demo stop` | LAPTOP |
| pack down | `./demo shutdown` | LAPTOP |
