#!/usr/bin/env bash
# Runs as root. Auth keys enter on stdin and are never command arguments.
# No --operator: the agent user cannot reconfigure the node (exit nodes,
# Funnel, serve); changes go through boxen, which runs this as root.
set +x
set -euo pipefail
# This helper may not see create's environment; the tailscale mixin records
# the preset chosen at create in a file.
preset="${BOXEN_SERVE_PRESET:-$(cat "${BOXEN_SERVE_PRESET_FILE:-/etc/boxen/serve-preset}" 2>/dev/null || true)}"
# Every node is tagged: a tagged node has no user's identity, so it gets
# none of the user's access and no Funnel grant aimed at members. The
# README's policy snippet names this tag.
tag=tag:boxen
# The node's name is public: tailscale serve fetches its HTTPS certificate
# from Let's Encrypt, and every certificate goes into the Certificate
# Transparency logs. So the name is random, never the sandbox's, and the
# guest keeps it so a rejoin reuses it.
hostname_file="${BOXEN_TS_HOSTNAME_FILE:-/etc/boxen/ts-hostname}"
hostname_re='^boxen-[0-9a-f]{8}$'
fail() { printf 'tailscale: %s\n' "$*" >&2; exit 1; }
node_name() {
  local name
  name="$(cat "$hostname_file" 2>/dev/null || true)"
  if [[ ! "$name" =~ $hostname_re ]]; then
    name="boxen-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    [[ "$name" =~ $hostname_re ]] || fail 'Could not make a node name'
    printf '%s\n' "$name" > "$hostname_file"
  fi
  printf '%s\n' "$name"
}
# Leave the tailnet rather than stay joined with access the policy did not intend.
leave() { tailscale logout || true; fail "$@"; }
wait_for_daemon() {
  local attempt=0
  until tailscale status --json >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [[ "$attempt" -lt 30 ]] || fail 'Daemon not ready; inspect /var/log/boxen/tailscaled.log'
    sleep 1
  done
}
# What the control plane granted this node, after up. Permissions come from
# every tag, so the tag set must be exactly the one tag: that catches a
# browser login by someone who does not own it and a key tagged otherwise or
# additionally. The Funnel check catches a nodeAttrs entry that would let a
# sudo-capable agent publish the sandbox to the internet. A node that cannot
# be read back leaves too; it is joined with whatever it was granted.
verify_node() {
  local self tags funnel
  self="$(tailscale status --self --peers=false --json)" || leave 'Could not verify the node after joining: tailscale status failed'
  dns_name="$(printf '%s' "$self" | jq -r '.Self.DNSName // "" | rtrimstr(".")')" || leave 'Could not verify the node after joining: unreadable status'
  tags="$(printf '%s' "$self" | jq -r '.Self.Tags // [] | join(",")')" || leave 'Could not verify the node after joining: unreadable status'
  funnel="$(printf '%s' "$self" | jq -r '.Self.CapMap // {} | keys[]
    | select(. == "funnel" or startswith("https://tailscale.com/cap/funnel"))')" || leave 'Could not verify the node after joining: unreadable status'
  [[ "$tags" == "$tag" ]] ||
    leave "The node joined with tags [${tags:-none}] instead of exactly $tag. Log in as an owner of $tag, or use a key tagged only $tag."
  [[ -z "$funnel" ]] ||
    leave "The tailnet policy grants this node Funnel, which could publish the sandbox to the internet; remove $tag from the funnel nodeAttrs."
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
      [[ "$preset" != supabase ]] ||
        fail 'The Supabase preset serves :443 from port 3000; run your app on 3000 instead.'
      mappings=("443:$target") ;;
  esac
  wait_for_daemon
  [[ -n "${dns_name:-}" ]] || dns_name="$(tailscale status --self --peers=false --json 2>/dev/null |
    jq -r '.Self.DNSName // "" | rtrimstr(".")' 2>/dev/null || true)"
  for pair in "${mappings[@]}"; do
    src="${pair%%:*}"; dst="${pair#*:}"
    tailscale serve --bg --https="$src" "http://127.0.0.1:$dst"
    if [[ "$src" == 443 ]]; then printf 'https://%s -> http://127.0.0.1:%s\n' "$dns_name" "$dst"
    else printf 'https://%s:%s -> http://127.0.0.1:%s\n' "$dns_name" "$src" "$dst"; fi
  done
}
case "${1:-}" in
  join)
    shift
    # No hostname argument: a sandbox name here would end up in public logs.
    [[ $# == 0 || ( $# == 1 && "$1" == --auth-key-stdin ) ]] || fail 'Use join [--auth-key-stdin]'
    wait_for_daemon
    hostname="$(node_name)"
    dns_name=""
    if [[ $# == 1 ]]; then
      umask 077
      auth_file="$(mktemp /var/run/tailscale/join.XXXXXX)"
      trap 'rm -f "$auth_file"' EXIT
      cat > "$auth_file"
      [[ -s "$auth_file" ]] || fail 'Empty auth key'
      tailscale up --auth-key="file:$auth_file" --hostname="$hostname" --advertise-tags="$tag"
      rm -f "$auth_file"
      trap - EXIT
    else
      tailscale up --hostname="$hostname" --advertise-tags="$tag"
    fi
    verify_node
    printf 'Joined as %s\n' "${dns_name:-$hostname}"
    # Userspace tailscaled forwards an incoming tailnet connection to the same
    # port on the guest's loopback, so every listening port is a preview
    # without serve, and without a certificate.
    printf 'Previews: http://%s:PORT for any port the sandbox listens on.\n' "${dns_name:-$hostname}"
    # tailscaled keeps serve config in its state, so the preset is applied once.
    if [[ "$preset" == supabase ]]; then serve supabase; fi
    tailscale status
    ;;
  serve)
    [[ $# == 2 ]] || fail 'Use serve PORT|supabase'
    serve "$2" ;;
  *) fail 'Use join [--auth-key-stdin] or serve PORT|supabase' ;;
esac
