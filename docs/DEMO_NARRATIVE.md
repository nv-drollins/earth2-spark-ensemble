# Demo Narrative — SC26

The one-page story this demo tells, why it lands with an SC audience, and the
exact words to say at the booth.

---

## The core idea (memorize this one sentence)

> **"A single forecast tells you what might happen. An ensemble tells you how
> much to trust it — and that's the question that actually matters."**

Everything else in the demo supports that sentence.

---

## Why an ensemble, and not just "look, AI predicts weather"

Every vendor on the SC floor can show a pretty forecast. A forecast that admits
its own uncertainty is a fundamentally more interesting claim, and it is the
reason weather centers buy supercomputers in the first place.

The physics: the atmosphere is chaotic. Two nearly identical starting states
diverge into visibly different futures. You cannot know the starting state
perfectly, so a single forecast is a lie of false precision. Operational
centers run **ensembles** — many forecasts from slightly perturbed starts — and
the *spread* between members is the forecast's honesty.

**This is what the demo makes visible, live, on three desk-side boxes.**

---

## The measured result the whole demo hangs on

Ensemble spread in 2 m temperature, 6 members, real GFS initial conditions:

| lead time | mean spread | max spread |
|---|---|---|
| 0 h  | **0.0004 K** | 0.00 K |
| 6 h  | 3.15 K | 18.21 K |
| 12 h | 4.31 K | 22.74 K |
| 24 h | 5.80 K | 28.08 K |
| 36 h | 7.02 K | 39.74 K |
| 48 h | **7.83 K** | 41.39 K |

Members start effectively identical and fan out monotonically. **That curve is
chaos theory, measured on your hardware, in about 30 seconds.**

It is also the perfect booth visual: six globes that start as one and visibly
separate.

---

## Driving the display by hand

Two direct controls on the aisle screen, both useful when a visitor asks a
question mid-story:

- **Drag any globe** to spin the whole ensemble. All six share one rotation
  phase, so they stay comparable.
- **Drag the ENSEMBLE DISAGREEMENT chart** to scrub through the forecast. It
  snaps to the 6-hour steps (the only leads that exist), and the globes, the
  lead-time readout and the marker all follow. Arrow keys step one lead at a
  time.

The scrub is the better way to make the divergence point than the automatic
playback: you can stop on the exact hour a visitor asks about, hold there while
you explain, then carry on. Dragging back to 0 h and forward again is a strong
"watch this" move.

## The 90-second booth script

**[0:00 — the hook, while the globe spins]**

> "This is a live weather forecast. Not a recording — we're running it right
> now on those three boxes under the table."

**[0:10 — establish the hardware, because it's absurd]**

> "Each one is a DGX Spark. 128 GB of unified memory, about the size of a
> paperback. Three of them are running a global atmospheric model at quarter-
> degree resolution — that's 720 by 1440 grid points, the whole planet."

**[0:25 — the turn, this is the important beat]**

> "But here's the thing nobody shows you. Watch what happens when I run it six
> times instead of once."

*(launch the ensemble; six globes appear)*

> "Same model. Same starting conditions — almost. I've perturbed the initial
> state by a fraction of a degree, which is far less than our real measurement
> error."

**[0:45 — the payoff]**

> "At hour zero they're identical. Look at the spread number — four ten-
> thousandths of a degree."

*(spread curve climbs as the forecast advances)*

> "Two days out, they disagree by nearly eight degrees on average, and by forty
> in places. That's not a bug. That's the atmosphere being chaotic, and it's
> exactly why forecasters run ensembles instead of one model."

**[1:10 — the "so what", aimed at the lab people]**

> "The spread map is the product. Red is where the forecast doesn't know. If
> you're routing aircraft or siting wind farms or issuing a storm warning,
> that's the map you want — not the pretty one."

**[1:25 — close on the hardware claim]**

> "Six ensemble members, five-day forecast, about thirty seconds. On three
> boxes you could carry in a backpack. That's a workflow that used to need a
> machine room."

---

## Who you're talking to, and how to pivot

SC has four distinct crowds. Read the badge and the first question.

### Lab / center staff (ORNL, LLNL, NCSA, DOE, university RC)
They will ask about **scaling and honesty**. Give them:
- "Six members across three nodes, round-robin. 16 GB per member, so roughly
  seven concurrent per Spark — about 21 across the three."
- "1.79 seconds per 6-hour step. The model is SFNO, 289 million parameters."
- Be first to say what it is NOT: "This is inference, not training. We're not
  claiming this replaces your allocation — it's where your postdoc develops and
  validates before spending one."

**Do not quote FLOPS.** If pressed on FP64: say plainly that GB10's silicon is
aimed at mixed-precision AI inference and that quoting an FP4 number against an
FP64 workload would be dishonest. That answer earns more respect than a number.

### Computational scientists (the CFD / chem / climate people)
They will ask **"is this model any good?"** Be straight:
- "SFNO is a neural surrogate trained on ERA5 reanalysis. It's skillful out to
  about a week and it is dramatically cheaper than numerical NWP. It does not
  replace a physics core — it complements it."
- The polar-stability story is a great credibility builder with this crowd:
  "We started with FourCastNet and it diverged to minus a thousand Kelvin at
  the South Pole — lat-lon grid singularity. SFNO uses spherical harmonics, no
  pole problem. Here's the before-and-after." *(see docs/PITFALLS.md #9)*
  Admitting a failure you diagnosed and fixed is the strongest possible signal
  that the rest of your numbers are real.

### Students / Student Cluster Competition teams
They want to **touch it and rebuild it**.
- "The whole thing is a public repo. Container recipe, cluster scripts,
  everything. github.com/nv-drollins/earth2-spark-ensemble"
- "Read PITFALLS.md before you start — there are eleven traps in this stack and
  we hit all of them."
- Let them run the ensemble themselves from the operator console.

### Directors / procurement
They want **where it fits**.
- "Desk-side development and validation for weather-climate AI. The expensive
  machine stays busy with production; this is where the iteration happens."
- "Three of these is a rounding error against a node-hour budget."

---

## Questions you WILL get, with honest answers

**"Is this actually running or is it a video?"**
> "Running. Pick a different initial date and watch it recompute." *(Then do it.)*

**"How does it compare to ECMWF/GFS?"**
> "SFNO is competitive with operational NWP at these lead times for many
> variables, at a tiny fraction of the compute. It's not universally better and
> we're not claiming it is."

**"Why not just one bigger machine?"**
> "Ensemble members are embarrassingly parallel — each is independent. Three
> nodes is three members at once. This is the rare workload where small
> independent boxes are genuinely the right shape."

**"What's the catch?"**
> "It's a surrogate model. It inherits the biases of its training data, it
> doesn't conserve mass or energy exactly, and it degrades past about ten days.
> For research and triage it's excellent. It isn't an operational replacement."

**"Could I run my own model on this?"**
> "Yes — the container is PhysicsNeMo, so anything in the Earth-2 stack works.
> CorrDiff for km-scale downscaling is the obvious next one."

**"Did you build this or did NVIDIA ship it?"**
> Split it cleanly: "The models and the container are NVIDIA's. The cluster
> automation, the offline distribution, and this visualization are ours. The
> pixels are mine; the science is NVIDIA's."

---

## What NOT to do at the booth

- **No pulsing / flashing / looping animation.** The globe rotates slowly and
  the spread curve advances. Nothing blinks.
- **No terminal visible to attendees, ever.** Everything runs from the operator
  console or a single button.
- **Don't oversell.** This audience detects it instantly and it costs you the
  rest of the conversation.
- **Don't let the FourCastNet numbers stand in for SFNO numbers.** Different
  model, 13x the memory, 2.6x the time.

---

## The one-line takeaway you want them to walk away repeating

> **"They ran a six-member global ensemble on three little boxes and showed me
> where the forecast doesn't know."**
