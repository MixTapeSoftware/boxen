#!/usr/bin/env bash
# Deliberately stops/restarts the named test environment. No personal credentials.
set -euo pipefail
[[ $# == 1 ]] || { echo "Usage: $0 TEST_SANDBOX" >&2; exit 2; }
project="$(cd "$(dirname "$0")/.." && pwd)"
name="$1"
sbx_bin="${SBX_BIN:-sbx}"
"$project/boxen" check "$name"
"$sbx_bin" exec "$name" docker info --format '{{.ServerVersion}}'
"$sbx_bin" exec --user root "$name" bash -c \
  'printf "%s\n" persisted > /var/lib/tailscale/.boxen-smoke'
"$sbx_bin" stop "$name"
"$sbx_bin" run -d --name "$name"
"$sbx_bin" exec --user root "$name" bash -c \
  'test "$(cat /var/lib/tailscale/.boxen-smoke)" = persisted'
# Startup hooks are asynchronous; allow the daemon to initialize its socket.
for ((attempt=0; attempt<30; attempt++)); do
  if "$sbx_bin" exec --user root "$name" tailscale status --json >/dev/null 2>&1; then break; fi
  sleep 1
done
"$sbx_bin" exec --user root "$name" tailscale status --json >/dev/null
"$sbx_bin" exec --user root "$name" bash -c 'test "$(pgrep -cx tailscaled)" = 1'
"$project/boxen" check "$name"
printf 'PASS sandbox restart, Docker daemon, and Tailscale volume persistence\n'
