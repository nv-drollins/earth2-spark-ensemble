#!/usr/bin/env bash
# Pre-stage SFNO model weights into CACHE_DIR on every node.
# RUN THIS WHILE YOU STILL HAVE INTERNET -- the SFNO checkpoint is ~6.9 GB and
# will NOT download at a venue with poor connectivity.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

for node in "${NODE_ARR[@]}"; do
  hdr "$node"
  DP=$(docker_prefix_for "$node")
  [[ "$DP" == "NEEDS_PASSWORD" ]] && { err "docker not usable"; continue; }

  if on_node "$node" "test -s '$CACHE_DIR/earth2studio/sfno/best_ckpt_mp0.tar'"; then
    sz=$(on_node "$node" "du -h '$CACHE_DIR/earth2studio/sfno/best_ckpt_mp0.tar' | cut -f1")
    ok "SFNO weights already cached ($sz) -- skipping"; continue
  fi

  echo "  downloading SFNO package (~6.9 GB)..."
  on_node "$node" "mkdir -p '$CACHE_DIR'"
  if on_node "$node" "${DP}docker run --rm --gpus all --ipc=host \
      -v '$CACHE_DIR':/root/.cache '$IMAGE' python -c \"
from earth2studio.models.px import SFNO
SFNO.load_model(SFNO.load_default_package())
print('FETCH_OK')
\"" | grep -q FETCH_OK; then
    ok "weights cached"
  else
    err "fetch failed"
  fi

  # The container runs as root, so everything it writes to the bind-mounted
  # cache is root-owned on the host. Hand it back so the login user can
  # rsync/inspect/delete it without sudo. (docs/PITFALLS.md #8)
  if on_node "$node" 'sudo -n true' 2>/dev/null; then
    on_node "$node" "sudo chown -R \"\$(id -u):\$(id -g)\" '$CACHE_DIR'" && ok "cache ownership fixed"
  else
    warn "cache files are root-owned (container ran as root)."
    echo "       To fix later:  sudo chown -R \$USER:\$USER $CACHE_DIR"
  fi
done
