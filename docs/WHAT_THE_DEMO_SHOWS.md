# What This Demo Shows

A plain-English explainer to accompany the demo video. No weather or
supercomputing background assumed.

---

## Start with something familiar

You've seen a weather forecast. Here's what's actually underneath one.

To predict weather, you need two things:

1. **A snapshot of the atmosphere right now** — temperature, pressure, wind and
   humidity, at many altitudes, everywhere on Earth. This comes from satellites,
   weather balloons, aircraft and ground stations, collected by agencies like
   NOAA. Forecasters call it the *initial conditions*.
2. **A way to compute forward** — given this state, what does the atmosphere look
   like in six hours? Then six hours after that. Repeat.

Traditionally step 2 means solving the physics equations of fluid motion on a
supercomputer. It works, and it is enormously expensive.

This demo does it differently. It uses an **AI model** — NVIDIA's SFNO — trained
on decades of historical weather. Rather than solving the equations, it learned
the patterns directly: shown the atmosphere now, it predicts the atmosphere six
hours from now. Same job, dramatically less compute.

**The spinning globe in the video is that forecast.** Colours are temperature.
Each step forward is six hours of weather.

---

## The problem nobody shows you

Here is the thing that makes forecasting genuinely hard, and it is not the
computing.

**You can never measure the starting state perfectly.** Weather stations are
scattered unevenly, satellites infer rather than measure directly, and every
instrument has finite precision. Your snapshot of "right now" is always slightly
wrong.

And in the atmosphere, **small errors do not stay small.** They amplify. A
difference too tiny to measure today becomes a different weather system next
week. This is the *butterfly effect* — discovered by meteorologist Edward Lorenz
in 1963, when he restarted a simulation from rounded-off numbers and got a
completely different forecast.

So a single forecast, presented as *the* answer, is quietly overconfident. It is
one plausible future among many.

---

## The fix: run it more than once

Instead of one forecast, run several — each starting from a slightly different
version of "now." Every version is equally consistent with what we actually
measured; they differ only within the error bars of our instruments.

That set of runs is called an **ensemble**, and each run is a **member**.

**This is the heart of the demo.** In the video:

- **Six globes appear.** Six forecasts, same AI model, starting conditions
  nudged by a fraction of a degree.
- **At hour zero they are indistinguishable.** The number on screen reads
  **0.0004 K** — four ten-thousandths of a degree apart. Effectively identical.
- **Then they separate.** As the forecast runs forward, the globes visibly
  diverge and the number climbs: 3.15 K at six hours, 5.80 K at a day,
  **7.83 K at two days** — and over 40 K in the most volatile spots.

That climbing number is the demo's whole point. **It is the butterfly effect,
measured, in about thirty seconds.** Nobody programmed the divergence; it
emerges because the atmosphere genuinely behaves this way.

This is not an exotic technique. Every major weather centre runs ensembles —
the European forecasting centre runs about fifty members operationally. It is
*the* standard method for knowing how much to trust a forecast.

---

## The map that's actually useful

The next beat drops the temperature view and shows **disagreement** instead:
how much the six runs differ, region by region.

- **Dark areas** — the members agree. The forecast is trustworthy here.
- **Red areas** — the members disagree sharply. The honest answer is *we don't
  know*.

This is the real product. If you are routing aircraft around storms, deciding
whether to issue a hurricane warning, or scheduling wind farms, the map you want
is not the pretty forecast — it is the one that tells you where the pretty
forecast is unreliable.

**One forecast tells you what might happen. An ensemble tells you how much to
trust it.**

---

## Zooming in

The last beat shows a different problem. The global model works on a grid of
about **25 km** per cell — an entire city fits in one or two cells. At that
resolution you cannot see individual thunderstorms, rain bands, or the way
mountains steer rainfall.

A second AI model, **CorrDiff**, takes that coarse forecast and generates
realistic fine-scale detail at about **2 km** — roughly **12× finer**. The video
shows both side by side: blocky squares on the left, individual rain bands and
storm cells on the right. Same weather, properly resolved.

To be clear about what this is: it is *not* movie-style "enhance," inventing
detail from nothing. CorrDiff was trained on real high-resolution observations
and learned what plausible fine structure looks like for a given large-scale
pattern — the same way a meteorologist knows a particular setup tends to produce
a line of storms along a front.

---

## Why the hardware matters

Everything above ran on **three NVIDIA DGX Sparks** — desk-side machines, each
about the size of a hardback book, with 128 GB of memory apiece.

| | |
|---|---|
| Model | SFNO, 289 million parameters |
| Grid | 0.25° global — 721 × 1440 points, the whole planet |
| Speed | 1.79 seconds per 6 hours of forecast |
| Memory | 16 GB per ensemble member |
| Six members | roughly 30 seconds |
| Zoom step | 3.3 seconds for a 12× resolution jump |

Ensemble forecasting has historically meant a machine room. The point of the
demo is not that these three boxes replace a national weather centre — they
don't. It is that the *entire workflow* now fits on a desk, which is where
researchers can actually develop and validate an idea before committing time on
a large shared system.

The six members are split across the three machines, two each, running at the
same time. Ensemble members are independent by nature, so this is one of the
rare workloads where several small machines are genuinely the right shape rather
than a compromise.

---

## Being straight about the limits

Worth saying plainly, because a technical audience will ask:

- **This is a surrogate model, not physics.** It inherits the biases of its
  training data, does not conserve mass and energy exactly, and degrades beyond
  roughly ten days. Excellent for research and rapid triage; not an operational
  replacement.
- **This is inference, not training.** We are running a pre-trained model, not
  building one.
- **Six members is a demonstration size.** Operational ensembles use dozens.

### One thing we caught, worth mentioning

The first model we tried, FourCastNet, produced temperatures of **minus 1100 K**
at the South Pole — physically impossible. The cause is a known geometry problem:
the model works on a latitude-longitude grid, and those grid lines converge at
the poles, so the maths breaks down there.

SFNO fixes it by working in spherical geometry, which has no such singularity.
Swapping models took the polar minimum from −1104 K back to a correct 198 K.

We mention it because it is the kind of failure that is easy to miss — the
*global average* looked perfectly fine the whole time. Only the extremes gave it
away.

---

## In one sentence

**Six AI weather forecasts, started from almost-identical conditions, visibly
disagreeing more and more as they run — showing not just what the weather might
do, but where the forecast itself can't be trusted, computed in seconds on three
machines that fit on a desk.**
