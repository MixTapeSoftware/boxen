#!/usr/bin/env bash
# Runs as root at create. BOXEN_FS_ROOT exists only so the tests can run it
# unprivileged.
set -euo pipefail
root="${BOXEN_FS_ROOT:-}"
workspace="$root/home/agent/workspace"
mkdir -p "$workspace"
chmod 0755 "$workspace"
if [[ "$(id -u)" == 0 ]]; then chown 1000:1000 "$workspace"; fi
# The short path most tools and habits expect; a real directory there is left alone.
if [[ ! -e "$root/workspace" || -L "$root/workspace" ]]; then ln -sfn /home/agent/workspace "$root/workspace"; fi
