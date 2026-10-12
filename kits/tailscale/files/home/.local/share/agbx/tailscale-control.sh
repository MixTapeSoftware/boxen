#!/usr/bin/env bash
# Runs as root. Auth keys enter on stdin and are never command arguments.
# No --operator: the agent user cannot reconfigure the node (exit nodes,
# Funnel, serve); changes go through agbx, which runs this as root.
set +x
set -euo pipefail
fail() { printf 'tailscale: %s\n' "$*" >&2; exit 1; }
wait_for_daemon() {
  local attempt=0
  until tailscale status --json >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [[ "$attempt" -lt 30 ]] || fail 'Daemon not ready; inspect /var/log/agbx/tailscaled.log'
    sleep 1
  done
}
serve() {
  local target="$1" pair src dst
  local mappings=()
  case "$target" in
    supabase) mappings=(443:3000 4410:3010 4431:3001 5432:54321 5433:54323 5434:54324 8443:8000) ;;
    *)
      [[ "$target" =~ ^[0-9]+$ && "${#target}" -le 5 ]] || fail 'Expected a port or supabase'
      target=$((10#$target))
      [[ "$target" -ge 1 && "$target" -le 65535 ]] || fail 'Port must be 1–65535'
      # The preset owns :443 -> 3000; replacing it would break the preset.
      [[ "${AGBX_SERVE_PRESET:-}" != supabase ]] ||
        fail 'The Supabase preset serves :443 from port 3000; run your app on 3000 instead.'
      mappings=("443:$target") ;;
  esac
  wait_for_daemon
  for pair in "${mappings[@]}"; do
    src="${pair%%:*}"; dst="${pair#*:}"
    tailscale serve --bg --https="$src" "http://127.0.0.1:$dst"
  done
}
case "${1:-}" in
  join)
    shift
    [[ $# -ge 1 ]] || fail 'Missing hostname'
    hostname="$1"; shift
    [[ "$hostname" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]+$ ]] || fail 'Invalid hostname'
    wait_for_daemon
    if [[ $# == 1 && "$1" == --auth-key-stdin ]]; then
      umask 077
      auth_file="$(mktemp /var/run/tailscale/join.XXXXXX)"
      trap 'rm -f "$auth_file"' EXIT
      cat > "$auth_file"
      [[ -s "$auth_file" ]] || fail 'Empty auth key'
      tailscale up --auth-key="file:$auth_file" --hostname="$hostname"
      rm -f "$auth_file"
      trap - EXIT
    elif [[ $# == 0 ]]; then
      tailscale up --hostname="$hostname"
    else fail 'Use join HOSTNAME [--auth-key-stdin]'; fi
    # tailscaled keeps serve config in its state, so the preset is applied once.
    if [[ "${AGBX_SERVE_PRESET:-}" == supabase ]]; then serve supabase; fi
    tailscale status
    ;;
  serve)
    [[ $# == 2 ]] || fail 'Use serve PORT|supabase'
    serve "$2" ;;
  *) fail 'Use join HOSTNAME [--auth-key-stdin] or serve PORT|supabase' ;;
esac
