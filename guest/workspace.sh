#!/usr/bin/env bash
# Runs as root at create: the user's workspace, where bxn clones the
# repository, linked from /workspace. BOXEN_FS_ROOT exists only so the tests
# can run it unprivileged.
set -euo pipefail
root="${BOXEN_FS_ROOT:-}"
user="${BOXEN_USER:-sprite}"
home="${BOXEN_HOME:-/home/$user}"
workspace="$root$home/workspace"
mkdir -p "$workspace"
chmod 0755 "$workspace"
if [[ "$(id -u)" == 0 ]]; then chown "$user:$user" "$workspace"; fi
# The short path most tools and habits expect; a real directory there is left alone.
if [[ ! -e "$root/workspace" || -L "$root/workspace" ]]; then ln -sfn "$home/workspace" "$root/workspace"; fi
