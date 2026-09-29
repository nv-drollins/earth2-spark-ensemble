# Pitfalls

Every trap below was hit for real while building this image on GB10 / DGX Spark
hardware. Each cost at least one failed build. They are listed in the order you
will encounter them.

The short version: **do not "simplify" the Dockerfile.** Every unusual line in it
exists because the obvious version does not work.

---

## 1. `pip install earth2studio[sfno]` silently DOWNGRADES earth2studio

**Symptom:** no error at install time. Later, `earth2studio.__version__` reports
`0.5.0` instead of `0.18.0`, and APIs are missing.

**Cause:** the `sfno` extra requires `makani`, which is **not on PyPI**
(`https://pypi.org/pypi/makani/json` returns 404). Pip cannot satisfy the extra
at 0.18.0, so instead of failing it backtracks through release history until it
finds a version whose dependencies it *can* satisfy -- landing on a 2-year-old
release. Resolver backtracking is silent by design.

**Fix:** install `makani` from GitHub **first**, then install a pinned
`earth2studio==0.18.0`. The Dockerfile asserts the version afterwards so a
regression fails the build loudly instead of shipping a broken image.

---

## 2. Container `onnxruntime-gpu` is too old for earth2studio 0.18

**Symptom:**
```
AttributeError: module 'onnxruntime' has no attribute 'preload_dlls'
```
raised at **import** time, from `earth2studio/models/utils.py`.

**Cause:** PhysicsNeMo 26.08 ships `onnxruntime-gpu` 1.20.2. `preload_dlls()`
was added in 1.21. This bites even though SFNO never touches ONNX, because
`earth2studio/models/px/__init__.py` eagerly imports the ONNX-backed `FengWu`
model -- importing *any* `px` model imports *all* of them.

**Fix:** `pip install --upgrade "onnxruntime-gpu>=1.21.0"`.

---

## 3. You CANNOT import SFNO during `docker build`

**Symptom:** a build-time smoke test like
`RUN python -c "from earth2studio.models.px import SFNO"` fails with:
```
OSError: libcuda.so.1: cannot open shared object file: No such file or directory
```
even though the image is perfectly good.

**Cause:** `makani` imports `transformer_engine`, which `dlopen()`s
`libcuda.so.1`. That library is injected by the NVIDIA container runtime only
at **run** time (`docker run --gpus all`). It does not exist during
`docker build`.

**Fix:** keep build-time guards to pure-Python checks (e.g. asserting the
earth2studio version) and verify SFNO at runtime with `scripts/verify.sh`.

---

## 4. makani `v0.2.1` vs `main` -- pick `main`

**Symptom:**
```
ModuleNotFoundError: No module named 'physicsnemo.models.meta'
```

**Cause:** makani's newest *release tag* (`v0.2.1`) targets an older PhysicsNeMo
API. Both `physicsnemo.models.meta` and `physicsnemo.registry` were **removed**
in PhysicsNeMo 2.2.0, which the 26.08 container ships.

**Fix:** pin `MAKANI_REF=main`. Counterintuitive -- the release tag is the wrong
choice here -- but the tag predates the API migration.

---

## 5. `precompute_latitudes` -- and why torch-harmonics comes from GitHub

**Symptom:**
```
ImportError: cannot import name 'precompute_latitudes' from 'torch_harmonics.quadrature'
```
surfaced through Earth2Studio as a generic `OptionalDependencyError`.

**Cause:** a genuine three-way version deadlock.
- makani `main` needs `torch_harmonics.quadrature.precompute_latitudes`, which
  first appears in torch-harmonics **0.9.0**.
- PyPI serves torch-harmonics only up to **0.8.0** for this container's
  cp312/aarch64 platform (0.8.1 is yanked; 0.9.x is not published for it).
- makani `v0.2.1` would work with 0.8.0, but see pitfall #4 -- it is
  incompatible with PhysicsNeMo 2.2.

There is **no makani commit** that satisfies both PhysicsNeMo 2.2 and
torch-harmonics 0.8.0. Checked: the commit that fixed the PhysicsNeMo API
(`02e643a`, 2026-08-05) already requires `precompute_latitudes`.

**Fix:** install torch-harmonics from GitHub at `v0.9.2`, bypassing PyPI.

---

## 6. torch-harmonics needs `--no-build-isolation`

**Symptom:**
```
RuntimeError: PyTorch is required to build torch-harmonics extensions.
UserWarning: PyTorch is not available, extensions will not be built: No module named 'torch'
```

**Cause:** torch-harmonics compiles CUDA extensions and its build backend
imports `torch` at build time. Pip's default isolated build environment cannot
see the container's torch.

**Fix:** `pip install --no-build-isolation ...`. Required on **both**
torch-harmonics install lines, including the re-assert near the end.

---

## 7. `--no-deps` on makani means supplying its dependencies by hand

**Symptom:** a slow drip of one-at-a-time failures at SFNO load, each reported
as `OptionalDependencyError`: `No module named 'ruamel'`, then
`No module named 'jsbeautifier'`, ...

**Cause:** makani is installed with `--no-deps` to stop it dragging in its own
`torch` / `nvidia-physicsnemo` / `torch-harmonics` and breaking the pins. That
also skips its harmless pure-Python deps.

**Fix:** install makani's declared dependencies explicitly, minus the three
pinned ones. Source of truth is makani's `pyproject.toml`
`[project].dependencies` -- read it rather than discovering modules one failed
build at a time.

---

## 8. Container-written cache files are root-owned

**Symptom:** `rsync`, `rm`, or `du` on `CACHE_DIR` fails with permission errors
for the login user.

**Cause:** the container runs as root, so every model checkpoint it writes into
the bind-mounted cache is owned by root on the host.

**Fix:** `scripts/fetch-models.sh` chowns the cache back to the invoking user
when passwordless sudo is available, and prints the manual command when it is
not. Never assume passwordless sudo exists.

---

## 9. FourCastNet is numerically unstable at the South Pole -- use SFNO

**Symptom:** 2 m temperature diverges to physically impossible values as the
forecast advances, while the global mean stays correct:

| lead | FourCastNet min | SFNO min |
|------|-----------------|----------|
| 0 h  | 198.55 K        | 198.55 K |
| 24 h | **-296.63 K**   | 197.80 K |
| 48 h | **-1104.81 K**  | 198.65 K |

**Cause:** the divergence is confined to 0.5% of grid cells, all between
-85.75 deg and -78.0 deg latitude -- the lat-lon grid singularity at the pole
in the original AFNO-based FourCastNet.

**Fix:** use SFNO. Its spherical harmonic transforms have no polar singularity.
Cells below 200 K drop from 0.53% to 0.033%, and the 0.01th percentile goes
from -980 K to 199.49 K.

**Cost of the fix:** 289.4M params vs 75.3M, 1.79 s/step vs 0.69 s, and
16.0 GB GPU vs 1.2 GB. Do not quote FourCastNet performance numbers for an
SFNO demo.

---

## 10. Build once, ship the tarball

The image is ~48.8 GB. Building it on each node needs internet on each node.

Measured on GB10: `docker save | zstd -3 -T0` produces a **14.1 GB** tarball in
**~2 min 54 s**. Compression only saves ~1.6% because the layers are already
compressed Python wheels -- zstd here is mostly about producing a single
portable file, not about size.

Budget ~80 GB free disk per node: 14 GB tarball + ~49 GB loaded image + ~7 GB
model weights + headroom.

---

## 11. Ensemble perturbation amplitude is in RAW units, not normalized

**Symptom:** the unperturbed control member is perfect, but every perturbed
member returns physically impossible fields -- `t2m` of **-1245 K to +1323 K**
with a global mean of **179 K** instead of ~280 K. No error is raised; the run
completes "successfully".

**Cause:** `SphericalGaussian(noise_amplitude=...)` broadcasts a scalar across
**all channels in their raw physical units**. A value like `0.05` looks tiny
but is applied identically to `t2m` (~280 K), `z500` (~5e4 m2/s2) and `msl`
(~1e5 Pa). Relative to geopotential it is negligible; relative to temperature
it compounds through the autoregressive rollout until the forecast explodes.

**Fix:** build a per-variable amplitude tensor scaled to each variable's
typical magnitude (see `ensemble/run_member.py`), and keep the default
`--noise` at **0.02**. Verified on GB10: 6 members give a 2.69 K ensemble mean
spread with every member physical.

**How to catch it:** always sanity-check `t2m` min/max/mean per member. The
control run passing proves nothing about the perturbed ones.
