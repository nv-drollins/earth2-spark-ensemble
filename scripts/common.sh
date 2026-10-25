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

# openshell COLOURISES its output even through a pipe, so `sandbox list` yields
# bytes like \e[32mReady\e[39m -- 15 bytes, not 5. A bare [[ "$phase" == Ready ]]
# therefore fails against a sandbox that IS Ready, and stripping whitespace does
# not help because the padding is escape sequences, not spaces. Strip SGR codes
# (and any CR) before comparing anything openshell printed.
strip_ansi() { sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\r//g'; }

# Phase of a sandbox on a node, de-colourised. Empty = no such sandbox.
sandbox_phase() {
  local target="$1" name="$2"
  on_node "$target" "openshell sandbox list 2>/dev/null" 2>/dev/null \
    | strip_ansi | awk -v n="$name" '$1==n {print $NF}' | tr -d '[:space:]'
}

# Remote paths MUST be expanded on the NODE, never on the control machine.
# $HOME on a laptop (/home/drollins) is NOT $HOME on a Spark (/home/nvidia),
# and `docker -v` SILENTLY CREATES a missing bind-mount source as a directory
# -- so a wrong path yields an empty mount and the baffling runtime error
#   /usr/bin/python: can't find '__main__' module in '/run_member.py'
# which names neither the path nor the mount. This only appears when the
# control machine's username differs from the nodes', so it hides completely
# while you drive the cluster from a machine with the same login.
# Cached per node: one SSH round-trip each, not one per member.
declare -A _E2_REMOTE_HOME
remote_home() {
  local target="$1"
  if [[ -z "${_E2_REMOTE_HOME[$target]:-}" ]]; then
    _E2_REMOTE_HOME[$target]=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      "$target" 'printf %s "$HOME"' 2>/dev/null)
    [[ -z "${_E2_REMOTE_HOME[$target]}" ]] && {
      err "could not resolve \$HOME on $target"; return 1; }
  fi
  printf '%s' "${_E2_REMOTE_HOME[$target]}"
}

# Rewrite a path templated on the LOCAL home into the node's own home.
# Run every remote path through this before ssh/scp/docker -v.
remote_path() {
  local target="$1" path="$2" rh
  rh=$(remote_home "$target") || return 1
  printf '%s' "${path/#$HOME/$rh}"
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
