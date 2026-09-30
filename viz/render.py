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


# --- coastlines -----------------------------------------------------------
# Derived from the SFNO package's own land_mask.nc (variable LSM), which is
# already on the exact 721x1440 forecast grid -- so the coastline lines up with
# the data by construction and needs no cartopy/geopandas/shapely.
# Extract once with scripts/make-landmask.sh.

_COAST_CACHE: dict[str, np.ndarray] = {}


def coastline_mask(shape: tuple[int, int], data_dir: str) -> np.ndarray | None:
    """Boolean edge mask: True on land/sea boundaries.

    Returns None when no land mask is available, so the overlay silently
    degrades to "no coastlines" rather than breaking a render.
    """
    key = f"{shape[0]}x{shape[1]}"
    if key in _COAST_CACHE:
        return _COAST_CACHE[key]
    path = os.path.join(data_dir, "land_mask.npy")
    if not os.path.isfile(path):
        return None
    lsm = np.load(path)
    if lsm.shape != shape:
        # Nearest-neighbour resample onto the field grid.
        ri = (np.linspace(0, lsm.shape[0] - 1, shape[0])).astype(np.int32)
        ci = (np.linspace(0, lsm.shape[1] - 1, shape[1])).astype(np.int32)
        lsm = lsm[ri][:, ci]
    land = lsm > 0.5
    # A coastline is any land cell adjacent to sea (4-neighbour). Rolling the
    # longitude axis wraps at the date line so there is no artificial seam.
    edge = np.zeros_like(land, dtype=bool)
    edge |= land & ~np.roll(land, 1, axis=1)
    edge |= land & ~np.roll(land, -1, axis=1)
    edge[1:, :] |= land[1:, :] & ~land[:-1, :]
    edge[:-1, :] |= land[:-1, :] & ~land[1:, :]
    _COAST_CACHE[key] = edge
    return edge


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
                 graticule: bool = True,
                 coast: np.ndarray | None = None) -> Image.Image:
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

    if coast is not None:
        # CONTRAST-AWARE stroke. A fixed brighten (+N) fails in both directions:
        # over pale desert the line vanishes into the data, and over dark ocean
        # it shouts louder than the science -- loudest where it is least needed.
        # Instead push each pixel AWAY from its own luminance, and fade the
        # stroke toward the limb where foreshortening turns coastlines into an
        # unreadable tangle.
        cm = coast[ri, ci] & disc & (z > 0.18)
        if cm.any():
            px = canvas[cm].astype(np.int16)
            lum = px.mean(axis=1, keepdims=True)
            direction = np.where(lum > 128, -1.0, 1.0)      # dark line on light data
            strength = (46 * np.clip(z[cm], 0, 1)[:, None] + 16) * direction
            canvas[cm] = (px + strength).clip(0, 255).astype(np.uint8)

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
        canvas[gr] = (canvas[gr].astype(np.int16) + 14).clip(0, 255).astype(np.uint8)

    img = Image.fromarray(canvas, "RGB")
    return img


def equirect_strip(field: np.ndarray, size: int = 512,
                   lut: np.ndarray = TEMP_LUT, vmin: float | None = None,
                   vmax: float | None = None, gamma: float = 1.0,
                   coast: np.ndarray | None = None) -> Image.Image:
    """Render the field as a flat equirectangular strip for CSS-sphere spinning.

    Why not pre-render rotated globes: a full spin needs ~24 angles per member
    per lead. Measured on this workstation that is 1296 images, ~6 minutes of
    render time and ~108 MB on disk -- and it still locks the demo to fixed
    rotation steps. One 2:1 strip per member per lead is 75 images total, and
    the browser can spin it continuously by animating background-position,
    which also makes mouse-drag possible for free.
    """
    if vmin is None:
        vmin = float(np.nanpercentile(field, 1))
    if vmax is None:
        vmax = float(np.nanpercentile(field, 99))
    norm = np.clip((field - vmin) / max(vmax - vmin, 1e-6), 0.0, 1.0)
    if gamma != 1.0:
        norm = norm ** gamma
    rgb = lut[(norm * 255).astype(np.uint8)]
    if coast is not None and coast.shape == field.shape:
        rgb = rgb.copy()
        px = rgb[coast].astype(np.int16)
        lum = px.mean(axis=1, keepdims=True)
        direction = np.where(lum > 128, -1.0, 1.0)
        rgb[coast] = (px + 52 * direction).clip(0, 255).astype(np.uint8)
    img = Image.fromarray(rgb, "RGB")
    # 2:1 aspect is what the CSS sphere shader expects (360 deg x 180 deg).
    return img.resize((size * 2, size), Image.BILINEAR)


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
        # Two DIFFERENT quantities, both in Kelvin, easily confused:
        #   spread  = standard deviation across members (what forecasters mean
        #             by "ensemble spread"). Robust to one outlier member.
        #   range   = hottest member minus coldest member at the same point.
        #             Always larger, and it is what people ASSUME "spread"
        #             means -- so report it explicitly rather than leaving the
        #             viewer to misread the std-dev maximum as a temperature
        #             gap between members.
        stack = np.stack([members[m][lead] for m in sorted(members)])
        rng = stack.max(axis=0) - stack.min(axis=0)
        rows.append({
            "lead_h": lead * 6,
            "mean_K": round(float(sd.mean()), 4),
            "max_K": round(float(sd.max()), 2),
            "p99_K": round(float(np.percentile(sd, 99)), 2),
            "range_mean_K": round(float(rng.mean()), 2),
            "range_max_K": round(float(rng.max()), 2),
        })
    return rows


def render_all(data_dir: str, out_dir: str, size: int = 900,
               spin_per_lead: float = 9.0, coastlines: bool = True) -> dict:
    """Render every frame the booth display needs."""
    members = load_members(data_dir)
    if not members:
        raise SystemExit(f"no member_*_t2m.npy found in {data_dir}")

    os.makedirs(out_dir, exist_ok=True)
    n_lead = min(a.shape[0] for a in members.values())

    # Shared colour scale across ALL members and leads, otherwise each frame
    # renormalizes and the globes appear to pulse -- which reads as animation
    # noise at a booth and hides the real signal.
    coast = coastline_mask(members[sorted(members)[0]][0].shape, data_dir) \
        if coastlines else None

    allv = np.concatenate([members[m][:n_lead].ravel() for m in sorted(members)])
    vmin, vmax = float(np.percentile(allv, 1)), float(np.percentile(allv, 99))

    # Spread scale fixed on the FINAL lead so growth is visible as brightening
    # rather than being renormalized away at every step.
    sd_final = spread_field(members, n_lead - 1)
    smin, smax = 0.0, float(np.percentile(sd_final, 99.5))

    manifest = {
        "coastlines_available": coast is not None,
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
            img = orthographic(members[m][lead], lon0, size, TEMP_LUT, vmin, vmax,
                               coast=coast)
            name = f"m{m:02d}_l{lead:02d}.jpg"
            img.save(os.path.join(out_dir, name), quality=88)
            # Flat strip for the browser-side spinning globe.
            equirect_strip(members[m][lead], 512, TEMP_LUT, vmin, vmax,
                           coast=coast).save(
                os.path.join(out_dir, f"strip_m{m:02d}_l{lead:02d}.jpg"), quality=82)
            # Bare variant so the display can toggle coastlines live and the
            # operator can judge whether they help or intrude.
            equirect_strip(members[m][lead], 512, TEMP_LUT, vmin, vmax).save(
                os.path.join(out_dir, f"bare_m{m:02d}_l{lead:02d}.jpg"), quality=82)
        sd = spread_field(members, lead)
        img = orthographic(sd, lon0, size, SPREAD_LUT, smin, smax, gamma=0.6,
                           coast=coast)
        sname = f"spread_l{lead:02d}.jpg"
        img.save(os.path.join(out_dir, sname), quality=88)
        equirect_strip(sd, 512, SPREAD_LUT, smin, smax, gamma=0.6,
                       coast=coast).save(
            os.path.join(out_dir, f"strip_spread_l{lead:02d}.jpg"), quality=82)
        equirect_strip(sd, 512, SPREAD_LUT, smin, smax, gamma=0.6).save(
            os.path.join(out_dir, f"bare_spread_l{lead:02d}.jpg"), quality=82)
        manifest["frames"][str(lead)] = {
            "lead_h": lead * 6,
            "members": [f"m{m:02d}_l{lead:02d}.jpg" for m in sorted(members)],
            "spread": sname,
            "strips": [f"strip_m{m:02d}_l{lead:02d}.jpg" for m in sorted(members)],
            "bare_strips": [f"bare_m{m:02d}_l{lead:02d}.jpg" for m in sorted(members)],
            "spread_strip": f"strip_spread_l{lead:02d}.jpg",
            "bare_spread_strip": f"bare_spread_l{lead:02d}.jpg",
        }

    with open(os.path.join(out_dir, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=2)
    return manifest




# --- CorrDiff km-scale downscaling ---------------------------------------

# Radar-style ramp for rainfall rate: transparent-dark for "no rain" rising to
# magenta for extreme cells. Matches the visual idiom meteorologists expect.
_RAIN_STOPS = [
    (0.00, (10, 14, 24)),
    (0.14, (24, 64, 120)),
    (0.32, (32, 150, 170)),
    (0.50, (86, 194, 96)),
    (0.66, (232, 214, 74)),
    (0.82, (230, 126, 40)),
    (0.93, (214, 44, 44)),
    (1.00, (226, 74, 196)),
]
RAIN_LUT = _ramp(_RAIN_STOPS)


def render_corrdiff(data_dir: str, out_dir: str, size: int = 900) -> dict:
    """Render the CorrDiff output as a flat high-resolution rainfall map.

    Deliberately NOT projected onto a globe: the point of this beat is that we
    have zoomed IN. A regional map at 448x448 next to the coarse 36x40 input is
    the whole story -- individual rain bands appear where the global model has
    only a handful of cells.
    """
    import json as _json

    arr = np.load(os.path.join(data_dir, "corrdiff.npy"))
    with open(os.path.join(data_dir, "corrdiff.json")) as fh:
        meta = _json.load(fh)

    # (batch, sample, variable, lat, lon) -> (variable, lat, lon)
    while arr.ndim > 3:
        arr = arr[0]
    out_vars = meta["out_vars"]
    mrr = arr[out_vars.index("mrr")]

    os.makedirs(out_dir, exist_ok=True)

    # Rainfall is extremely right-skewed; a linear scale shows almost nothing.
    field = np.clip(mrr, 0.0, None)
    vmax = float(np.percentile(field, 99.5)) or 1.0
    norm = np.clip(field / vmax, 0.0, 1.0) ** 0.55
    rgb = RAIN_LUT[(norm * 255).astype(np.uint8)]
    img = Image.fromarray(rgb, "RGB").resize((size, size), Image.NEAREST)
    img.save(os.path.join(out_dir, "corrdiff_fine.jpg"), quality=90)

    # Coarse comparison panel: block-average to the INPUT grid so the audience
    # sees exactly what the global model had to work with.
    ch, cw = meta["in_shape"][1], meta["in_shape"][2]
    fh_, fw_ = field.shape
    coarse = field[: (fh_ // ch) * ch, : (fw_ // cw) * cw]
    coarse = coarse.reshape(ch, fh_ // ch, cw, fw_ // cw).mean(axis=(1, 3))
    cnorm = np.clip(coarse / vmax, 0.0, 1.0) ** 0.55
    crgb = RAIN_LUT[(cnorm * 255).astype(np.uint8)]
    Image.fromarray(crgb, "RGB").resize((size, size), Image.NEAREST).save(
        os.path.join(out_dir, "corrdiff_coarse.jpg"), quality=90)

    meta["rain_vmax"] = round(vmax, 3)
    with open(os.path.join(out_dir, "corrdiff_manifest.json"), "w") as fh:
        _json.dump(meta, fh, indent=2)
    return meta


if __name__ == "__main__":
    import argparse

    p = argparse.ArgumentParser()
    p.add_argument("--data", default=os.path.expanduser("~/e2viz/data"))
    p.add_argument("--out", default=os.path.expanduser("~/e2viz/frames"))
    p.add_argument("--size", type=int, default=900)
    args = p.parse_args()

    man = render_all(args.data, args.out, args.size)
    if os.path.isfile(os.path.join(args.data, "corrdiff.npy")):
        cd = render_corrdiff(args.data, args.out, args.size)
        print(f"corrdiff: {cd['in_shape'][1]}x{cd['in_shape'][2]} -> "
              f"{cd['out_shape'][-2]}x{cd['out_shape'][-1]} "
              f"({cd['resolution_gain']}x) in {cd['run_s']}s")
    print(f"rendered {man['n_lead']} leads x {len(man['members'])} members -> {args.out}")
    print("spread curve:")
    for row in man["curve"]:
        print(f"  {row['lead_h']:3d}h  mean {row['mean_K']:7.4f} K   max {row['max_K']:6.2f} K")
