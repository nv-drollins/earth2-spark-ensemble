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
    # 0.02 verified on GB10 to give a realistic ensemble spread while keeping
    # every member physical. 0.05 pushes tail members to ~345 K / ~134 K.
    p.add_argument("--noise", type=float, default=0.02, help="perturbation amplitude for members > 0")
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
        # IMPORTANT: noise_amplitude is broadcast across ALL channels in their
        # RAW physical units, not normalized ones. A scalar like 0.05 looks
        # tiny but is applied identically to t2m (~280 K), z500 (~5e4) and
        # msl (~1e5), which destabilises the rollout -- members come back with
        # t2m of -1245 K / +1323 K and a global mean of 179 K while the
        # unperturbed control stays perfectly physical. Scale the amplitude to
        # each variable instead: ~0.1% of its typical magnitude.
        ic = model.input_coords()
        var_names = list(ic["variable"])
        amp = torch.full((len(var_names),), 0.05)
        for i, name in enumerate(var_names):
            if name.startswith("z"):        # geopotential, ~5e4
                amp[i] = 50.0 * args.noise
            elif name.startswith("msl") or name.startswith("sp"):  # pressure, ~1e5
                amp[i] = 100.0 * args.noise
            elif name.startswith(("t", "u", "v")):  # temperature/wind, O(1-300)
                amp[i] = 0.1 * args.noise
            else:
                amp[i] = 0.01 * args.noise
        amp = amp.reshape(1, 1, -1, 1, 1)
        arr = ensemble(
            [args.date], args.steps, 1, model, GFS(), io.ZarrBackend(),
            perturbation=SphericalGaussian(noise_amplitude=amp),
            batch_size=1,
        )
    run_s = time.time() - t1

    # NOTE: do not iterate arr.root with .items() -- earth2studio 0.18 uses
    # zarr v3, whose Group exposes .arrays()/.keys(), not .items(). Calling
    # .items() raises AttributeError: 'Group' object has no attribute 'items'.
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
