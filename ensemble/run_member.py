"""Run one perturbed SFNO ensemble member and write it to NetCDF.

Executed inside the container by scripts/ensemble.sh. One member per process;
the shell script fans these out across the cluster.
"""
import argparse, json, os, time

import numpy as np
import torch


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--member", type=int, required=True, help="member index; 0 = unperturbed control")
    p.add_argument("--date", required=True, help="initial condition date, YYYY-MM-DD")
    p.add_argument("--steps", type=int, default=20, help="number of 6-hour steps (20 = 5 days)")
    p.add_argument("--noise", type=float, default=0.05, help="perturbation amplitude for members > 0")
    p.add_argument("--outdir", default="/out")
    args = p.parse_args()

    from earth2studio.data import GFS
    from earth2studio.models.px import SFNO
    import earth2studio.io as io
    from earth2studio.run import deterministic, ensemble

    t0 = time.time()
    model = SFNO.load_model(SFNO.load_default_package()).to("cuda")
    load_s = time.time() - t0
    print(f"[m{args.member}] model loaded in {load_s:.1f}s", flush=True)

    os.makedirs(args.outdir, exist_ok=True)
    out = os.path.join(args.outdir, f"member_{args.member:03d}.nc")

    t1 = time.time()
    if args.member == 0:
        # Control run: no perturbation.
        arr = deterministic([args.date], args.steps, model, GFS(), io.ZarrBackend())
    else:
        # Perturbed member. Seed from the member index so runs are reproducible
        # across nodes and reruns -- important for a demo you rehearse.
        from earth2studio.perturbation import SphericalGaussian
        torch.manual_seed(args.member)
        arr = ensemble(
            [args.date], args.steps, 1, model, GFS(), io.ZarrBackend(),
            perturbation=SphericalGaussian(noise_amplitude=args.noise),
            batch_size=1,
        )
    run_s = time.time() - t1

    import xarray as xr
    ds = xr.Dataset({k: (v.dims, np.asarray(v)) for k, v in arr.root.items()
                     if hasattr(v, "dims")}) if hasattr(arr, "root") else None
    try:
        t2m = np.asarray(arr["t2m"])
        np.save(os.path.join(args.outdir, f"member_{args.member:03d}_t2m.npy"), t2m)
    except Exception as exc:  # pragma: no cover - diagnostics only
        print(f"[m{args.member}] WARN could not extract t2m: {exc}", flush=True)
        t2m = None

    peak_gb = torch.cuda.max_memory_allocated() / 1e9
    meta = {
        "member": args.member,
        "date": args.date,
        "steps": args.steps,
        "load_s": round(load_s, 2),
        "run_s": round(run_s, 2),
        "s_per_step": round(run_s / max(args.steps, 1), 3),
        "gpu_peak_gb": round(peak_gb, 2),
        "node": os.uname().nodename,
    }
    if t2m is not None:
        meta["t2m_min_K"] = round(float(t2m.min()), 2)
        meta["t2m_max_K"] = round(float(t2m.max()), 2)
        meta["t2m_mean_K"] = round(float(t2m.mean()), 2)

    with open(os.path.join(args.outdir, f"member_{args.member:03d}.json"), "w") as fh:
        json.dump(meta, fh, indent=2)
    print("MEMBER_DONE " + json.dumps(meta), flush=True)


if __name__ == "__main__":
    main()
