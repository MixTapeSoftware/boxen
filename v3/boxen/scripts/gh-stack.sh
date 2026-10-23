#!/usr/bin/env bash
# GitHub's gh stack extension for stacked PRs, pinned. v0.2.1 is the
# commit 29a36d314be664583705f18e41cebdf2b61ad514, which the Dockerfile also
# takes the extension's agent skill from. The checksums are the digests GitHub
# publishes for the release's binaries, which their build provenance (signed
# by gh-stack's release workflow at that tag) also covers.
set -euo pipefail
source /etc/boxen/env.sh
version=v0.2.1
case "$(uname -m)" in
  x86_64) arch=amd64; checksum=ffe9d48b6342faffc3b0cb420202ff1df32e24faf32693debd7423274bbdf859 ;;
  aarch64|arm64) arch=arm64; checksum=25ec261a391261a1462d38f85c230b0e0b14ae3547926130996541f62f25f78b ;;
  *) echo 'Unsupported architecture' >&2; exit 1 ;;
esac
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "https://github.com/github/gh-stack/releases/download/$version/linux-$arch" -o "$tmp/gh-stack"
printf '%s  %s\n' "$checksum" "$tmp/gh-stack" | sha256sum -c --quiet -
# Where gh looks for extensions, with the manifest gh writes for a pinned
# install, so gh extension upgrade leaves it alone.
dir="${XDG_DATA_HOME:-$HOME/.local/share}/gh/extensions/gh-stack"
mkdir -p "$dir"
install -m 755 "$tmp/gh-stack" "$dir/gh-stack"
printf 'owner: github\nname: gh-stack\nhost: github.com\ntag: %s\nispinned: true\npath: %s\n' \
  "$version" "$dir/gh-stack" > "$dir/manifest.yml"
gh stack --version
