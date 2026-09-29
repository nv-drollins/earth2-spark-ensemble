#!/usr/bin/env bash
# RUNTIME verification. This is the real smoke test -- the Dockerfile
# deliberately cannot check SFNO at build time (see docs/PITFALLS.md #3).
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

FAIL=0
for node in "${NODE_ARR[@]}"; do
  hdr "$node"
  DP=$(docker_prefix_for "$node")
  [[ "$DP" == "NEEDS_PASSWORD" ]] && { err "docker not usable"; FAIL=1; continue; }

  if ! on_node "$node" "${DP}docker image inspect '$IMAGE' >/dev/null 2>&1"; then
    err "$IMAGE not present -- run scripts/distribute.sh"; FAIL=1; continue
  fi

  out=$(on_node "$node" "${DP}docker run --rm --gpus all --ipc=host \
      -v '$CACHE_DIR':/root/.cache '$IMAGE' python -c \"
import torch, earth2studio, makani, torch_harmonics
assert torch.cuda.is_available(), 'CUDA not available'
from earth2studio.models.px import SFNO
print('VERIFY_OK', torch.__version__, torch.cuda.get_device_name(0), earth2studio.__version__)
\"" 2>&1)

  if grep -q VERIFY_OK <<< "$out"; then
    ok "$(grep VERIFY_OK <<< "$out")"
  else
    err "verification failed:"; sed 's/^/       /' <<< "$(tail -12 <<< "$out")"; FAIL=1
  fi
done

hdr "Result"
if [[ $FAIL -eq 0 ]]; then c_grn "All nodes verified."; else c_red "Verification FAILED."; exit 1; fi
