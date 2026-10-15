# Show-Floor Runbook

Everything you need on site, in the order you need it.

---

## One command for everything

```bash
cd ~/earth2-spark-ensemble

./demo check      # night before: full readiness check
./demo start      # doors open
./demo status     # what is running, what is not
./demo stop       # doors close
./demo restart    # when something feels stuck
```

`./demo status` is the one to remember. It shows the display server and its
URLs, which nodes will run members, whether the agent's model is loaded, and
whether the sandbox is ready — in one screen.

---

## Getting the demo onto the hardware

Only the build node needs internet, and only once. **Do this at the office.**

```bash
cp cluster.conf.example cluster.conf && $EDITOR cluster.conf   # SSH targets
./scripts/preflight.sh      # check every node BEFORE pulling 48 GB
./scripts/build.sh          # build once -> one 14.1 GB tarball
./scripts/distribute.sh     # load the image onto every node
./scripts/stage-offline.sh --with-agent   # EVERYTHING else the demo downloads
```

`stage-offline.sh` replaces `fetch-models.sh` for show prep: it stages SFNO
**and** the three artifacts `fetch-models.sh` does not — CorrDiff weights, the
GFS initial conditions, and the agent's LLM — then writes a `MANIFEST.sha256`
in each directory so you can prove the USB copy arrived intact. Re-running it
is cheap; it skips whatever is already staged.

Then carry these on a USB stick:

| directory | what | size |
|---|---|---|
| `$BUNDLE_DIR` (`~/e2dist`) | the image tarball | **14.1 GB** |
| `$CACHE_DIR` (`~/e2cache`) | SFNO weights, CorrDiff weights, pinned initial conditions | **~8 GB** |
| `~/.cache/huggingface` *(agent node only)* | the agent's ~30B LLM | **~30 GB** |

The last two rows are the ones that used to bite. **CorrDiff weights** are
fetched at *run* time by `run_corrdiff.py`, so without them the rainfall panel
is simply absent — `render.py` omits it with no error. **The LLM** lives in
`~/.cache/huggingface` on the agent node, not in `$CACHE_DIR`, so it travels in
its own directory. Export `HF_TOKEN` before staging: the Hub throttles
anonymous downloads and a 30 GB NVFP4 checkpoint feels it.

On site, with no internet:

```bash
./scripts/distribute.sh                    # copy + load the image (~4 min/node)
./scripts/stage-offline.sh --verify --date <staged-date>   # checksums, no downloads
./scripts/verify.sh                        # runtime SFNO + CUDA check
./demo check                               # full readiness
```

### Pin the date, or the ensemble phones home

`ensemble.sh` and `corrdiff.sh` default `DATE` to **two days ago**, which is a
different date by the time you reach the venue. Nothing is staged for it, so
they fall back to a live NOAA fetch and fail. Use the date you staged, on both:

```bash
DATE=2026-10-13 MEMBERS=6 STEPS=20 ./scripts/ensemble.sh
DATE=2026-10-13 ./scripts/corrdiff.sh
```

When a staged IC is present, `ensemble.sh` says `using staged IC for <date>
(offline)` and skips the download entirely.

Budget **~80 GB free disk per node**: 14 GB tarball + 49 GB loaded image +
8 GB weights + headroom. The agent node needs **~30 GB more** for the LLM.


---

## Daily rhythm at the booth

**Morning (~10 min before doors):**

```bash
./demo start
./demo status      # confirm all green
```

The agent's LLM takes **4–6 minutes** to load. `./demo start` kicks it off in
the background and returns immediately, so start it first and pour coffee. The
globes work the whole time — only the Ask/Plan panel needs the model.

Then open two browser windows:

- **`/display`** on the aisle-facing screen (fullscreen, F11)
- **`/operator`** on your laptop

**Evening (leaving the hardware on):**

```bash
./demo stop
```

Leaves the LLM and sandbox running on purpose — they cost nothing idle and take
five minutes to come back.

**Pack-down (powering the Sparks off):**

```bash
./demo shutdown     # stops the display + every container on every node
```

Then power the Sparks off from their desktops, or
`ssh <node> 'sudo poweroff'`.

On the next boot, `./demo start` is all you need — **rendered frames survive a
reboot**, so there is nothing to re-render unless you want a fresh ensemble.

### Every command runs on the WORKSTATION

`./demo` lives on the machine driving the display, **not** on a Spark. It
reaches the nodes over SSH. You never log into a Spark to start or stop the
demo.

---

## If something goes wrong

| symptom | fix |
|---|---|
| Display blank / won't load | `./demo restart` |
| Agent panel errors | LLM still loading. `./demo status`, wait, retry |
| Globes not spinning | hard-refresh the browser (Ctrl+Shift+R) |
| A member failed | `./demo status` — a node is probably low on memory |
| Everything looks wrong | `./demo restart`, then re-render: `python3 viz/render.py` |

**The display serves pre-rendered frames.** A cluster hiccup mid-conversation
cannot blank your screen — the globes, the spread map and the scrub control all
keep working even if every Spark goes offline. Only "Plan & Run" needs live
nodes.

### Nuclear option

If the demo is unrecoverable and a visitor is standing there, the frames on the
workstation are self-contained:

```bash
./viz/start-display.sh     # display only, no cluster needed at all
```

That still gives you the full story: six globes, divergence, uncertainty map,
CorrDiff zoom. Only live re-runs are lost.

---

## Node roles (worth knowing before someone asks)

| node | ensemble members | CorrDiff | agent LLM |
|---|---|---|---|
| Spark 1 | **3** | yes | — |
| Spark 2 | **3** | — | — |
| Spark 3 | **0** | — | **yes** |
| Workstation | — | — | — (renders + serves the UI) |

**The third Spark does not participate in forecasting at all.** Not the
ensemble, not the downscaling. It hosts the ~30B language model for the agent,
which leaves about **15 GB** free of its 128 GB unified memory — and an SFNO
member needs **16 GB**. One gigabyte short.

`scripts/ensemble.sh` probes free memory per node and skips any below the
threshold, so members are split evenly across the two nodes that can hold them.
`scripts/corrdiff.sh` uses the first node in the list. The third Spark is
touched only by `collect.sh`, which sweeps every node for output files.

The node is fully capable — the forecast image and SFNO weights are staged on
it. Stop the LLM and it immediately contributes 2 of 6 members.

This is **reported, never silent**: `./demo status` prints
`only 15G free -- will be SKIPPED for members`. A run that quietly returns
fewer members than requested is the failure mode this exists to prevent.

To free it, move the LLM to a GPU workstation and set `E2_AGENT_NODE` — see
[docs/WORKSTATION.md](WORKSTATION.md#freeing-the-third-spark-for-forecasting).

---

## Don't do these on the floor

- **Don't re-run `./scripts/build.sh`.** It needs internet and takes 15 minutes.
- **Don't `docker rm` the LLM container** unless you have 6 minutes spare.
- **Don't run a Plan & Run while a visitor is mid-question** — it takes minutes.
  Use **Plan** (instant, no compute) to show the reasoning instead.
- **Don't leave a stale agent answer on screen** between visitors. The operator
  console has a **Clear** button.
