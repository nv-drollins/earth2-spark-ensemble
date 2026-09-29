#!/usr/bin/env bash
# Shared helpers. Sourced by every script in scripts/.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="${CONF:-$REPO_ROOT/cluster.conf}"

if [[ ! -f "$CONF" ]]; then
  echo "ERROR: $CONF not found. Copy cluster.conf.example to cluster.conf and edit it." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONF"

: "${NODES:?NODES must be set in cluster.conf}"
: "${IMAGE:?IMAGE must be set in cluster.conf}"
: "${BUNDLE_DIR:?BUNDLE_DIR must be set in cluster.conf}"
: "${CACHE_DIR:?CACHE_DIR must be set in cluster.conf}"

read -r -a NODE_ARR <<< "$NODES"
BUILD_NODE="${NODE_ARR[0]}"

c_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
ok()   { c_grn  "  OK   $*"; }
warn() { c_ylw  "  WARN $*"; }
err()  { c_red  "  FAIL $*"; }
hdr()  { printf '\n=== %s ===\n' "$*"; }

# Run a command on a node. Uses bash -lc because some images/hosts have
# .bashrc early-returns for non-interactive shells.
on_node() {
  local target="$1"; shift
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$target" "bash -lc $(printf '%q' "$*")"
}

# Docker may require sudo if the login user is not in the docker group.
# NEVER assume passwordless sudo -- probe and report instead.
docker_prefix_for() {
  local target="$1"
  if on_node "$target" 'id -nG | tr " " "\n" | grep -qx docker' 2>/dev/null; then
    printf ''
  elif on_node "$target" 'sudo -n true' 2>/dev/null; then
    printf 'sudo '
  else
    printf 'NEEDS_PASSWORD'
  fi
}
