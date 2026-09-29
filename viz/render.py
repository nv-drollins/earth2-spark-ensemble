"""Render ensemble output into booth-ready visuals.

Produces, from the .npy files written by ensemble/run_member.py:
  - orthographic globe frames per member per lead time (the spinning Earth)
  - an ensemble-spread globe (where the forecast disagrees -- the money shot)
  - a spread-growth curve (chaos, measured)

Pure numpy + PIL. No matplotlib, no cartopy, no network. Runs on the operator
workstation, not the cluster.
"""
from __future__ import annotations

import glob
import json
import os

import numpy as np
from PIL import Image, ImageDraw


# --- colour maps -----------------------------------------------------------
# Perceptually reasonable ramps built by hand so we need no matplotlib.

_TEMP_STOPS = [
    (0.00, (8, 24, 68)),      # deep cold
    (0.20, (24, 92, 176)),
    (0.40, (96, 176, 224)),
    (0.52, (236, 240, 232)),  # near freezing
    (0.65, (248, 208, 96)),
    (0.82, (232, 116, 40)),
    (1.00, (140, 20, 28)),    # hot
]

# Sequential (not diverging) ramp: spread is a one-sided quantity. Starts at a
# visible slate rather than near-black so "low but real" spread is still
# readable -- a near-black low end throws away most of the dynamic range.
_SPREAD_STOPS = [
    (0.00, (30, 38, 56)),     # agreement -- recedes but stays visible
    (0.22, (46, 96, 138)),
    (0.45, (62, 162, 158)),
    (0.68, (206, 196, 92)),
    (0.85, (232, 140, 52)),
    (1.00, (236, 54, 48)),    # disagreement -- jumps out at 30 feet
]


def _ramp(stops):
    """Expand colour stops into a 256-entry lookup table."""
    lut = np.zeros((256, 3), dtype=np.uint8)
    xs = [s[0] for s in stops]
    for i in range(256):
        t = i / 255.0
        k = np.searchsorted(xs, t, side="right") - 1
        k = max(0, min(k, len(stops) - 2))
        t0, c0 = stops[k]
        t1, c1 = stops[k + 1]
        f = 0.0 if t1 == t0 else (t - t0) / (t1 - t0)
        lut[i] = [int(round(c0[j] + f * (c1[j] - c0[j]))) for j in range(3)]
    return lut


TEMP_LUT = _ramp(_TEMP_STOPS)
SPREAD_LUT = _ramp(_SPREAD_STOPS)


def load_members(data_dir: str) -> dict[int, np.ndarray]:
    """Load member t2m arrays, normalized to (lead, lat, lon).

    The control member comes from earth2studio's `deterministic` and is 4-D;
    perturbed members come from `ensemble` and carry an EXTRA leading ensemble
    axis (5-D). Squeezing leading singleton axes normalizes both, otherwise
    np.stack raises "all input arrays must have the same shape".
    """
    out: dict[int, np.ndarray] = {}
    for path in sorted(glob.glob(os.path.join(data_dir, "member_*_t2m.npy"))):
        arr = np.load(path)
        while arr.ndim > 3:
            arr = arr[0]
        member = int(os.path.basename(path).split("member_")[1][:3])
        out[member] = arr
    return out


def orthographic(field: np.ndarray, lon0: float, size: int = 900,
                 lut: np.ndarray = TEMP_LUT, vmin: float | None = None,
                 vmax: float | None = None, gamma: float = 1.0,
                 graticule: bool = True) -> Image.Image:
    """Project an equirectangular field onto a globe seen from (0, lon0).

    Nearest-neighbour sampling: fast, and at booth viewing distance
    indistinguishable from interpolated.
    """
    nlat, nlon = field.shape
    if vmin is None:
        vmin = float(np.nanpercentile(field, 1))
    if vmax is None:
        vmax = float(np.nanpercentile(field, 99))

    # Screen-space grid in [-1, 1]; x right, y up.
    yy, xx = np.mgrid[0:size, 0:size]
    x = (xx - size / 2.0) / (size / 2.0 * 0.94)
    y = (size / 2.0 - yy) / (size / 2.0 * 0.94)
    rho2 = x * x + y * y
    disc = rho2 <= 1.0

    # Inverse orthographic projection (globe centred on the equator).
    z = np.sqrt(np.clip(1.0 - rho2, 0.0, 1.0))
    lat = np.degrees(np.arcsin(np.clip(y, -1.0, 1.0)))
    lon = lon0 + np.degrees(np.arctan2(x, z))
    lon = (lon + 180.0) % 360.0 - 180.0

    # Map lat/lon to array indices. Row 0 is +90 lat, col 0 is 0 lon.
    ri = np.clip(((90.0 - lat) / 180.0 * (nlat - 1)).astype(np.int32), 0, nlat - 1)
    ci = np.clip((((lon % 360.0) / 360.0) * nlon).astype(np.int32), 0, nlon - 1)

    vals = field[ri, ci]
    norm = np.clip((vals - vmin) / max(vmax - vmin, 1e-6), 0.0, 1.0)
    if gamma != 1.0:
        # gamma < 1 lifts the low end. Spread fields are strongly
        # right-skewed: without this, most of the globe crushes to the darkest
        # colour and the low-to-moderate range is invisible.
        norm = norm ** gamma
    idx = (norm * 255).astype(np.uint8)
    rgb = lut[idx]

    # Limb shading: darken toward the edge so the sphere reads as a sphere.
    shade = (0.45 + 0.55 * z)[..., None]
    rgb = (rgb * shade).astype(np.uint8)

    canvas = np.zeros((size, size, 3), dtype=np.uint8)
    canvas[disc] = rgb[disc]

    if graticule:
        # Faint 30-degree grid gives the eye a geographic anchor. Without any
        # reference an uncertainty blob is unlocatable -- "somewhere on Earth"
        # is not a useful answer at a booth.
        gr = np.zeros((size, size), dtype=bool)
        for glat in range(-60, 61, 30):
            gr |= np.abs(lat - glat) < 0.32
        dlon = np.abs(((lon - lon0 + 180.0) % 360.0) - 180.0)
        for glon in range(-180, 180, 30):
            off = np.abs(((lon - glon + 180.0) % 360.0) - 180.0)
            gr |= (off < 0.32 * np.maximum(np.cos(np.radians(lat)), 0.05))
        gr &= disc & (z > 0.06)
        canvas[gr] = (canvas[gr].astype(np.int16) + 26).clip(0, 255).astype(np.uint8)

    img = Image.fromarray(canvas, "RGB")
    return img


def spread_field(members: dict[int, np.ndarray], lead: int) -> np.ndarray:
    """Standard deviation across members at one lead time."""
    stack = np.stack([members[m][lead] for m in sorted(members)])
    return stack.std(axis=0)


def spread_curve(members: dict[int, np.ndarray]) -> list[dict]:
    """Mean/max ensemble spread at every lead time -- the chaos curve."""
    n_lead = min(a.shape[0] for a in members.values())
    rows = []
    for lead in range(n_lead):
        sd = spread_field(members, lead)
        rows.append({
            "lead_h": lead * 6,
            "mean_K": round(float(sd.mean()), 4),
            "max_K": round(float(sd.max()), 2),
            "p99_K": round(float(np.percentile(sd, 99)), 2),
        })
    return rows


def render_all(data_dir: str, out_dir: str, size: int = 900,
               spin_per_lead: float = 9.0) -> dict:
    """Render every frame the booth display needs."""
    members = load_members(data_dir)
    if not members:
        raise SystemExit(f"no member_*_t2m.npy found in {data_dir}")

    os.makedirs(out_dir, exist_ok=True)
    n_lead = min(a.shape[0] for a in members.values())

    # Shared colour scale across ALL members and leads, otherwise each frame
    # renormalizes and the globes appear to pulse -- which reads as animation
    # noise at a booth and hides the real signal.
    allv = np.concatenate([members[m][:n_lead].ravel() for m in sorted(members)])
    vmin, vmax = float(np.percentile(allv, 1)), float(np.percentile(allv, 99))

    # Spread scale fixed on the FINAL lead so growth is visible as brightening
    # rather than being renormalized away at every step.
    sd_final = spread_field(members, n_lead - 1)
    smin, smax = 0.0, float(np.percentile(sd_final, 99.5))

    manifest = {
        "members": sorted(members),
        "n_lead": n_lead,
        "temp_range_K": [round(vmin, 2), round(vmax, 2)],
        "spread_range_K": [smin, round(smax, 2)],
        "curve": spread_curve(members),
        "frames": {},
    }

    for lead in range(n_lead):
        lon0 = (lead * spin_per_lead) % 360.0
        for m in sorted(members):
            img = orthographic(members[m][lead], lon0, size, TEMP_LUT, vmin, vmax)
            name = f"m{m:02d}_l{lead:02d}.jpg"
            img.save(os.path.join(out_dir, name), quality=88)
        sd = spread_field(members, lead)
        img = orthographic(sd, lon0, size, SPREAD_LUT, smin, smax, gamma=0.6)
        sname = f"spread_l{lead:02d}.jpg"
        img.save(os.path.join(out_dir, sname), quality=88)
        manifest["frames"][str(lead)] = {
            "lead_h": lead * 6,
            "members": [f"m{m:02d}_l{lead:02d}.jpg" for m in sorted(members)],
            "spread": sname,
        }

    with open(os.path.join(out_dir, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=2)
    return manifest


if __name__ == "__main__":
    import argparse

    p = argparse.ArgumentParser()
    p.add_argument("--data", default=os.path.expanduser("~/e2viz/data"))
    p.add_argument("--out", default=os.path.expanduser("~/e2viz/frames"))
    p.add_argument("--size", type=int, default=900)
    args = p.parse_args()

    man = render_all(args.data, args.out, args.size)
    print(f"rendered {man['n_lead']} leads x {len(man['members'])} members -> {args.out}")
    print("spread curve:")
    for row in man["curve"]:
        print(f"  {row['lead_h']:3d}h  mean {row['mean_K']:7.4f} K   max {row['max_K']:6.2f} K")
