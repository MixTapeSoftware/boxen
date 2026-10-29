#!/usr/bin/env bash
set -euo pipefail
source /etc/boxen/env.sh
version=2.30.0
case "$(uname -m)" in
  x86_64) arch=amd64; checksum=cd5361b074cd40eb2b332885f35a4d61c74369919ced95190c885f4d4f739dc7 ;;
  aarch64|arm64) arch=arm64; checksum=c0618a4d4defa5d61606dfb4eaf7d5f39cf6361382c4943449df95fa1f7cc310 ;;
  *) echo 'Unsupported architecture' >&2; exit 1 ;;
esac
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "https://cache.agilebits.com/dist/1P/op2/pkg/v$version/op_linux_${arch}_v$version.zip" -o "$tmp/op.zip"
printf '%s  %s\n' "$checksum" "$tmp/op.zip" | sha256sum -c --quiet -
unzip -q "$tmp/op.zip" -d "$tmp/op"
install -m 755 "$tmp/op/op" "$HOME/.local/bin/op"
op --version
