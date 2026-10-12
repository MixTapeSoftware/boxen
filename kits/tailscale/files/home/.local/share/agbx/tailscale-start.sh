#!/usr/bin/env bash
set -euo pipefail
mkdir -p /var/lib/tailscale /var/run/tailscale /var/log/agbx
chmod 700 /var/lib/tailscale
# Prevent duplicate daemons on repeated startup dispatches. flock releases on exit.
exec 9>/var/run/tailscale/agbx.lock
flock -n 9 || exit 0
exec tailscaled \
  --tun=userspace-networking \
  --state=/var/lib/tailscale/tailscaled.state \
  --socket=/var/run/tailscale/tailscaled.sock \
  --socks5-server=127.0.0.1:1055 \
  >> /var/log/agbx/tailscaled.log 2>&1
