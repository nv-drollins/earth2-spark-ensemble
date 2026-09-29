# syntax=docker/dockerfile:1
# Earth-2 ensemble demo image for NVIDIA GB10 / DGX Spark (linux/arm64)
# Base: official NGC PhysicsNeMo container (torch + CUDA + physicsnemo, arm64)
ARG BASE_IMAGE=nvcr.io/nvidia/physicsnemo/physicsnemo:26.08
FROM ${BASE_IMAGE}

# ---------------------------------------------------------------------------
# torch-harmonics -- install from GitHub, NOT PyPI.
# PyPI only serves up to 0.8.0 for this container's cp312/arm64 platform
# (0.8.1 is yanked, 0.9.x is not published for it), but makani needs
# torch_harmonics.quadrature.precompute_latitudes, which first appears in
# 0.9.0. Installing the PyPI version yields, at SFNO load time:
#   ImportError: cannot import name 'precompute_latitudes'
# ---------------------------------------------------------------------------
# --no-build-isolation is REQUIRED: torch-harmonics compiles CUDA extensions
# and its build backend imports torch at build time. In an isolated build env
# the container's torch is invisible and the wheel build dies with
#   RuntimeError: PyTorch is required to build torch-harmonics extensions.
ARG TH_REF=v0.9.2
RUN pip install --no-cache-dir --no-build-isolation \
    "torch_harmonics @ git+https://github.com/NVIDIA/torch-harmonics.git@${TH_REF}"

# ---------------------------------------------------------------------------
# makani -- NOT on PyPI (pypi.org/pypi/makani/json -> 404).
#  (a) `pip install earth2studio[sfno]` silently backtracks
#      earth2studio 0.18.0 -> 0.5.0 because the resolver cannot satisfy the
#      makani extra. Install makani from source FIRST so the extra resolves.
#  (b) Use main, NOT the v0.2.1 release tag. v0.2.1 imports
#      physicsnemo.models.meta / physicsnemo.registry, both REMOVED in
#      PhysicsNeMo 2.2.0 which this container ships ->
#      ModuleNotFoundError: No module named 'physicsnemo.models.meta'.
#      There is no makani commit that works with both PhysicsNeMo 2.2 and
#      torch-harmonics 0.8.0, which is why TH comes from git above.
# ---------------------------------------------------------------------------
ARG MAKANI_REF=main
RUN pip install --no-cache-dir --no-deps \
    "makani @ git+https://github.com/NVIDIA/makani.git@${MAKANI_REF}"

# makani was installed with --no-deps (to protect the earth2studio and
# torch-harmonics pins), so its own runtime imports must be supplied
# explicitly. Deliberately EXCLUDES torch / nvidia-physicsnemo (container's
# own builds) and torch-harmonics (pinned above).
# Source of truth: makani pyproject.toml [project].dependencies.
RUN pip install --no-cache-dir \
    "h5py>=3.11.0" "wandb>=0.13.7" numba "tqdm>=4.60.0" "pynvml>=10.0.0" \
    jsbeautifier more-itertools importlib-metadata \
    "ruamel.yaml>=0.18.10" moviepy

ARG E2S_VERSION=0.18.0
RUN pip install --no-cache-dir "earth2studio==${E2S_VERSION}"

# The 26.08 container ships onnxruntime-gpu 1.20.2, but earth2studio 0.18
# calls ort.preload_dlls() (added in 1.21). Without this the package raises
# AttributeError at IMPORT time -- even for SFNO, which never uses ONNX,
# because models/px/__init__.py eagerly imports the ONNX-backed FengWu.
RUN pip install --no-cache-dir --upgrade "onnxruntime-gpu>=1.21.0"

# Re-assert the torch-harmonics pin: installing earth2studio may have pulled
# the PyPI 0.8.0 back in to satisfy its own >=0.8.0 floor.
RUN pip install --no-cache-dir --force-reinstall --no-deps --no-build-isolation \
    "torch_harmonics @ git+https://github.com/NVIDIA/torch-harmonics.git@${TH_REF}"

# Build-time guard: catch a silent pip downgrade of earth2studio.
# NOTE: we deliberately do NOT import SFNO here. makani pulls in
# transformer_engine, which dlopen()s libcuda.so.1 -- injected by the NVIDIA
# runtime only at RUN time (--gpus all) -- so an import-SFNO check during
# `docker build` fails with OSError even on a perfectly good image.
# SFNO import is verified at runtime by scripts/verify.sh instead.
RUN python -c "import earth2studio,sys; v=earth2studio.__version__; \
    sys.exit(0) if v=='${E2S_VERSION}' else (_ for _ in ()).throw(SystemExit(f'earth2studio downgraded to {v}'))"

WORKDIR /workspace
