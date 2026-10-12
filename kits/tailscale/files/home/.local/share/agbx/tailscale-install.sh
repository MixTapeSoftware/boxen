#!/usr/bin/env bash
set -euo pipefail
# A static release avoids systemd/package post-install scripts starting an
# unconfigured daemon, and works independently of the Ubuntu release.
version=1.104.1
case "$(uname -m)" in
  x86_64) arch=amd64; checksum=108d1d96ecf410d305571e173516f27038f870919a9b89c914a167c6d33a4528 ;;
  aarch64|arm64) arch=arm64; checksum=f60294374967f3dfd8cf57bbbd474d6cfce32d123e3a8ddeab82a87940daa806 ;;
  *) echo 'Unsupported Tailscale architecture' >&2; exit 1 ;;
esac
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${version}_$arch.tgz" -o "$tmp/tailscale.tgz"
printf '%s  %s\n' "$checksum" "$tmp/tailscale.tgz" | sha256sum -c --quiet -
tar -C "$tmp" -xzf "$tmp/tailscale.tgz"
install -m 755 "$tmp/tailscale_${version}_$arch/tailscale" /usr/local/bin/tailscale
install -m 755 "$tmp/tailscale_${version}_$arch/tailscaled" /usr/local/bin/tailscaled
install -m 755 /home/agent/.local/share/agbx/tailscale-control.sh /usr/local/bin/agbx-tailscale
mkdir -p /var/lib/tailscale /var/run/tailscale /var/log/agbx
chmod 700 /var/lib/tailscale
