#!/usr/bin/env bash
# Pull ensemble member output from every node back to the workstation for
# rendering. Idempotent; safe to re-run.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

LOCAL="${E2_DATA:-$HOME/e2viz/data}"
OUTDIR="${OUTDIR:-$HOME/e2out}"
mkdir -p "$LOCAL"

for node in "${NODE_ARR[@]}"; do
  hdr "$node"
  # Container runs as root, so member files are root-owned on the host.
  # Hand them back before copying, when we can do so without a password.
  if on_node "$node" 'sudo -n true' 2>/dev/null; then
    on_node "$node" "sudo chown -R \"\$(id -u):\$(id -g)\" '$OUTDIR' 2>/dev/null" || true
  fi
  if scp -o BatchMode=yes -q "$node:$OUTDIR/member_*" "$LOCAL/" 2>/dev/null; then
    ok "collected"
  else
    warn "nothing to collect (has the ensemble run?)"
  fi
done

n=$(ls "$LOCAL"/member_*_t2m.npy 2>/dev/null | wc -l)
hdr "Result"
[[ "$n" -gt 0 ]] && c_grn "$n member arrays in $LOCAL" || c_red "no member arrays collected"
