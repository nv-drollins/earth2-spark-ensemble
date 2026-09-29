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

n=${#NODE_ARR[@]}
pids=()
for ((m=0; m<MEMBERS; m++)); do
  node="${NODE_ARR[$((m % n))]}"
  DP=$(docker_prefix_for "$node")
  [[ "$DP" == "NEEDS_PASSWORD" ]] && { err "docker not usable on $node"; continue; }

  on_node "$node" "mkdir -p '$OUTDIR' '$RUNDIR'"
  # Ship the member script to the node rather than assuming the repo is
  # cloned there -- the cluster nodes need no git checkout at all.
  scp -o BatchMode=yes -q "$REPO_ROOT/ensemble/run_member.py" "$node:$RUNDIR/run_member.py"
  echo "  member $m -> $node"
  on_node "$node" "${DP}docker run --rm --gpus all --ipc=host \
      -v '$CACHE_DIR':/root/.cache -v '$OUTDIR':/out \
      -v '$RUNDIR/run_member.py':/run_member.py \
      '$IMAGE' python /run_member.py \
      --member $m --date '$DATE' --steps $STEPS --outdir /out" \
      > "/tmp/e2_member_${m}.log" 2>&1 &
  pids+=($!)
done

fail=0
for pid in "${pids[@]}"; do wait "$pid" || fail=1; done

hdr "Results"
grep -h MEMBER_DONE /tmp/e2_member_*.log 2>/dev/null | sed 's/MEMBER_DONE //' || warn "no member output"
[[ $fail -eq 0 ]] && c_grn "Ensemble complete." || c_red "One or more members failed -- see /tmp/e2_member_*.log"
