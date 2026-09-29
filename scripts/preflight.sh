#!/usr/bin/env bash
# Verify every node can build/run the Earth-2 image BEFORE downloading 48 GB.
# Safe to re-run. Read-only: changes nothing.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

FAIL=0
for node in "${NODE_ARR[@]}"; do
  hdr "$node"

  if ! on_node "$node" true 2>/dev/null; then
    err "SSH failed (need key-based auth: ssh-copy-id $node)"; FAIL=1; continue
  fi
  ok "SSH"

  arch=$(on_node "$node" 'uname -m')
  [[ "$arch" == "aarch64" ]] && ok "arch $arch" || { err "arch $arch (expected aarch64/GB10)"; FAIL=1; }

  if on_node "$node" 'command -v nvidia-smi >/dev/null'; then
    drv=$(on_node "$node" 'nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1')
    gpu=$(on_node "$node" 'nvidia-smi --query-gpu=name --format=csv,noheader | head -1')
    ok "GPU $gpu (driver $drv)"
  else
    err "nvidia-smi missing"; FAIL=1
  fi

  if on_node "$node" 'command -v docker >/dev/null'; then
    dp=$(docker_prefix_for "$node")
    if [[ "$dp" == "NEEDS_PASSWORD" ]]; then
      err "docker present but user is not in the 'docker' group and sudo needs a password."
      echo "       Fix (run once on $node, then re-login):  sudo usermod -aG docker \$USER"
      FAIL=1
    else
      ok "docker usable${dp:+ (via sudo)}"
      # The container toolkit is what actually injects libcuda.so.1 at runtime.
      if on_node "$node" "${dp}docker info 2>/dev/null | grep -qi nvidia"; then
        ok "NVIDIA container runtime registered"
      else
        warn "NVIDIA container runtime not visible in 'docker info' -- --gpus all may fail"
      fi
    fi
  else
    err "docker missing"; FAIL=1
  fi

  # 14 GB tarball + 48 GB loaded image + ~7 GB weights. 80 GB is a safe floor.
  avail=$(on_node "$node" "df -BG --output=avail \"\$HOME\" 2>/dev/null | tail -1 | tr -dc '0-9'")
  if [[ -n "$avail" && "$avail" -ge 80 ]]; then ok "disk ${avail}G free"
  else err "disk ${avail:-?}G free (need >=80G)"; FAIL=1; fi

  mem=$(on_node "$node" "free -g | awk '/Mem/{print \$2}'")
  ok "memory ${mem}G unified"

  on_node "$node" 'command -v zstd >/dev/null' && ok "zstd" || \
    warn "zstd missing (install: sudo apt-get install -y zstd) -- needed to load the bundle"
done

hdr "Result"
if [[ $FAIL -eq 0 ]]; then c_grn "Preflight PASSED for all nodes."; else c_red "Preflight FAILED -- fix the above before continuing."; exit 1; fi
