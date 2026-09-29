"""Run CorrDiff km-scale downscaling -- the "zoom in" second act.

CorrDiffTaiwan takes a COARSE 36x40 (0.25 deg, ~25 km) patch and generates a
448x448 field at ~2 km resolution -- a 12x resolution jump -- producing radar
reflectivity (mrr), 2 m temperature and 10 m winds.

Visually this is the strongest beat in the demo: the global ensemble answers
"where is the forecast uncertain", then CorrDiff dives into one of those
regions and resolves individual rain bands the global model cannot represent.

Needs NO extra dependencies: CorrDiff rides on nvidia-physicsnemo, which the
SFNO image already carries. Verified importable in earth2-spark:dev.
"""
from __future__ import annotations

import argparse
import json
import os
import time

import numpy as np
import torch


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--date", default="2026-09-20", help="initial condition date")
    p.add_argument("--samples", type=int, default=1, help="diffusion samples to draw")
    p.add_argument("--outdir", default="/out")
    args = p.parse_args()

    from earth2studio.data import GFS
    from earth2studio.models.dx import CorrDiffTaiwan

    t0 = time.time()
    model = CorrDiffTaiwan.load_model(CorrDiffTaiwan.load_default_package())
    model = model.to("cuda")
    model.number_of_samples = args.samples
    load_s = time.time() - t0
    print(f"[corrdiff] loaded in {load_s:.1f}s "
          f"({sum(q.numel() for q in model.parameters())/1e6:.1f}M params)", flush=True)

    ic = model.input_coords()
    in_vars = list(ic["variable"])
    in_lat, in_lon = np.asarray(ic["lat"]), np.asarray(ic["lon"])

    # Pull exactly the coarse inputs CorrDiff expects for its Taiwan domain.
    ds = GFS()
    da = ds(np.datetime64(args.date + "T00"), in_vars)
    arr = np.asarray(da.values)          # (time, variable, lat, lon) global
    glat = np.asarray(da.coords["lat"])
    glon = np.asarray(da.coords["lon"])

    # Nearest-neighbour subset onto CorrDiff's 36x40 input grid.
    ri = np.abs(glat[:, None] - in_lat[None, :]).argmin(axis=0)
    ci = np.abs((glon[:, None] % 360) - (in_lon[None, :] % 360)).argmin(axis=0)
    patch = arr[0][:, ri][:, :, ci]      # (variable, 36, 40)

    x = torch.from_numpy(np.ascontiguousarray(patch)).float().unsqueeze(0).to("cuda")
    print(f"[corrdiff] input {tuple(x.shape)} -> running diffusion", flush=True)

    t1 = time.time()
    with torch.inference_mode():
        out, oc = model(x, ic)
    run_s = time.time() - t1

    out_np = out.detach().float().cpu().numpy()
    out_vars = list(oc["variable"])
    olat = np.asarray(oc["lat"]); olon = np.asarray(oc["lon"])

    os.makedirs(args.outdir, exist_ok=True)
    np.save(os.path.join(args.outdir, "corrdiff.npy"), out_np)
    np.save(os.path.join(args.outdir, "corrdiff_lat.npy"), olat)
    np.save(os.path.join(args.outdir, "corrdiff_lon.npy"), olon)

    # Resolution gain is the headline: coarse cells -> fine cells.
    fine = out_np.shape[-1] * out_np.shape[-2]
    coarse = patch.shape[-1] * patch.shape[-2]
    meta = {
        "date": args.date,
        "samples": args.samples,
        "load_s": round(load_s, 2),
        "run_s": round(run_s, 2),
        "in_shape": list(patch.shape),
        "out_shape": list(out_np.shape),
        "in_vars": in_vars,
        "out_vars": out_vars,
        "lat_range": [float(olat.min()), float(olat.max())],
        "lon_range": [float(olon.min()), float(olon.max())],
        "resolution_gain": round((fine / coarse) ** 0.5, 1),
        "gpu_peak_gb": round(torch.cuda.max_memory_allocated() / 1e9, 2),
    }
    for i, v in enumerate(out_vars):
        f = out_np[..., i, :, :] if out_np.ndim > 3 else out_np[i]
        meta[f"{v}_min"] = round(float(np.nanmin(f)), 3)
        meta[f"{v}_max"] = round(float(np.nanmax(f)), 3)
        meta[f"{v}_mean"] = round(float(np.nanmean(f)), 3)

    with open(os.path.join(args.outdir, "corrdiff.json"), "w") as fh:
        json.dump(meta, fh, indent=2)
    print("CORRDIFF_DONE " + json.dumps(meta), flush=True)


if __name__ == "__main__":
    main()
