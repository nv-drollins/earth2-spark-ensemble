#!/usr/bin/env bash
# Fan N ensemble members out across the cluster, round-robin by node.
#
# Sizing (measured on GB10, SFNO, 720x1440 global grid):
#   ~16.0 GB GPU peak per member, ~1.79 s per 6-hour step.
#   121 GB unified memory per Spark => ~7 concurrent members/node,
#   ~21 across three Sparks. A 5-day (20-step) member takes ~36 s.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MEMBERS="${MEMBERS:-6}"
DATE="${DATE:-$(date -u -d '2 days ago' +%Y-%m-%d)}"
STEPS="${STEPS:-20}"
OUTDIR="${OUTDIR:-$HOME/e2out}"
RUNDIR="${RUNDIR:-$HOME/e2run}"

hdr "Ensemble: $MEMBERS members, init $DATE, $STEPS x 6h steps"
echo "Nodes: ${NODE_ARR[*]}"

# Skip nodes with too little free memory to hold a 16 GB SFNO member. The
# agent node also hosts a ~35B vLLM, so scheduling a member there OOMs with
# "torch.AcceleratorError: CUDA error: out of memory" -- and because members
# run in parallel, that failure is easy to miss among the successes.
# Override with E2_MIN_FREE_GB=0 to schedule on every node regardless.
MIN_FREE_GB="${E2_MIN_FREE_GB:-24}"
RUN_NODES=()
for node in "${NODE_ARR[@]}"; do
  # Clear stale member output on EVERY node, including ones we are about to
  # skip. A skipped node keeps whatever it produced in an earlier run, and
  # collect.sh still pulls from it -- those stale files then overwrite the
  # fresh ones and silently corrupt the ensemble (symptom: two members match
  # each other exactly but differ from the rest by ~35 K at lead 0).
  on_node "$node" "rm -f \$HOME/e2out/member_* 2>/dev/null" || true
  free_gb=$(on_node "$node" "free -g | awk '/Mem/{print \$7}'" 2>/dev/null | tr -d '\r')
  if [[ -n "$free_gb" && "$free_gb" -ge "$MIN_FREE_GB" ]]; then
    RUN_NODES+=("$node")
  else
    warn "$node has ${free_gb:-?}G free (<${MIN_FREE_GB}G) -- skipping, it cannot hold a member"
  fi
done
[[ ${#RUN_NODES[@]} -eq 0 ]] && { err "no node has enough free memory for a member"; exit 1; }

# WARM THE INITIAL-CONDITION CACHE FIRST, on every run node, one at a time.
# All members must start from the SAME initial conditions -- that is the entire
# premise of an ensemble. Launching them in parallel against a cold cache makes
# several of them race on the same GFS download: some read a partially-written
# or stale entry and silently run a DIFFERENT initial condition. The symptom is
# subtle and easy to miss -- spread at lead 0 is ~1.2 K instead of ~0.0004 K,
# and the odd members differ from the rest by up to 32 K globally while every
# member still looks individually plausible.
hdr "Warming initial-condition cache"
for node in "${RUN_NODES[@]}"; do
  DP=$(docker_prefix_for "$node")
  on_node "$node" "mkdir -p '$OUTDIR' '$RUNDIR'"
  scp -o BatchMode=yes -q "$REPO_ROOT/ensemble/run_member.py" "$node:$RUNDIR/run_member.py"
  echo "  $node"
  # Materialise the FULL initial condition to a file every member then reads.
  # Warming the cache is not enough: independent GFS() calls can still resolve
  # to different analyses. A shared file makes "identical inputs" structural.
  on_node "$node" "${DP}docker run --rm --gpus all --ipc=host \
      -v '$CACHE_DIR':/root/.cache -v '$OUTDIR':/out \
      '$IMAGE' python -c \"
import numpy as np
from earth2studio.data import GFS
from earth2studio.models.px import SFNO
m = SFNO.load_model(SFNO.load_default_package())
v = list(m.input_coords()['variable'])
da = GFS()(np.datetime64('${DATE}T00'), v)
da.to_netcdf('/out/ic_${DATE}.nc')
print('IC_WRITTEN', da.shape)\"" >/dev/null 2>&1 || warn "IC fetch failed on $node"
done
ok "shared initial conditions written"

n=${#RUN_NODES[@]}

# Keep the ensemble balanced across the nodes that can actually run it.
# Without this, MEMBERS=8 on 2 usable nodes leaves an uneven split, and a
# member scheduled onto a skipped node simply never appears -- the display
# then shows fewer members than the plan promised, with no error anywhere.
if (( MEMBERS % n != 0 )); then
  adjusted=$(( (MEMBERS / n) * n ))
  (( adjusted < n )) && adjusted=$n
  warn "adjusting $MEMBERS members -> $adjusted so they divide evenly across $n usable node(s)"
  MEMBERS=$adjusted
fi

pids=()
for ((m=0; m<MEMBERS; m++)); do
  node="${RUN_NODES[$((m % n))]}"
  DP=$(docker_prefix_for "$node")
  [[ "$DP" == "NEEDS_PASSWORD" ]] && { err "docker not usable on $node"; continue; }

  # Clear prior member output on this node. Without this a SMALLER run leaves
  # the previous run's extra members on disk; collect.sh then pulls them and
  # the display mixes two different forecasts (visible as members carrying an
  # older init date in the results block).
  on_node "$node" "mkdir -p '$OUTDIR' '$RUNDIR' && rm -f '$OUTDIR'/member_*" 
  # Ship the member script to the node rather than assuming the repo is
  # cloned there -- the cluster nodes need no git checkout at all.
  scp -o BatchMode=yes -q "$REPO_ROOT/ensemble/run_member.py" "$node:$RUNDIR/run_member.py"
  echo "  member $m -> $node"
  on_node "$node" "${DP}docker run --rm --gpus all --ipc=host \
      -v '$CACHE_DIR':/root/.cache -v '$OUTDIR':/out \
      -v '$RUNDIR/run_member.py':/run_member.py \
      '$IMAGE' python /run_member.py \
      --member $m --date '$DATE' --steps $STEPS --outdir /out \
      --ic-file /out/ic_${DATE}.nc" \
      > "/tmp/e2_member_${m}.log" 2>&1 &
  pids+=($!)
done

fail=0
for pid in "${pids[@]}"; do wait "$pid" || fail=1; done

hdr "Results"
grep -h MEMBER_DONE /tmp/e2_member_*.log 2>/dev/null | sed 's/MEMBER_DONE //' || warn "no member output"
[[ $fail -eq 0 ]] && c_grn "Ensemble complete." || c_red "One or more members failed -- see /tmp/e2_member_*.log"
