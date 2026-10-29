#!/usr/bin/env bash
set -euo pipefail
source /etc/boxen/env.sh
case "$(uname -m)" in
  x86_64) arch=x86_64; checksum=a59974c74e3fddfd040f80618a0f7eae535ebe58d91aa1d8d876bc99815dc037 ;;
  aarch64|arm64) arch=arm64; checksum=b256faf57feea83058a4bfcdedffd60a3724c47b7d2f096207c7a55f51d387d5 ;;
  *) echo 'Unsupported architecture' >&2; exit 1 ;;
esac
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "https://github.com/AlexanderGrooff/mermaid-ascii/releases/download/1.4.0/mermaid-ascii_Linux_$arch.tar.gz" -o "$tmp/mermaid.tar.gz"
printf '%s  %s\n' "$checksum" "$tmp/mermaid.tar.gz" | sha256sum -c --quiet -
tar -C "$tmp" -xzf "$tmp/mermaid.tar.gz" mermaid-ascii
install -m 755 "$tmp/mermaid-ascii" "$HOME/.local/bin/mermaid-ascii"
