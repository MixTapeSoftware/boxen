#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git wget unzip zip jq zsh tmux gnupg \
  build-essential pkg-config autoconf automake bison cmake re2c \
  libssl-dev libncurses-dev libreadline-dev zlib1g-dev libbz2-dev \
  libsqlite3-dev libffi-dev liblzma-dev libyaml-dev libxml2-dev libxslt1-dev \
  libcurl4-openssl-dev libonig-dev libzip-dev libpng-dev libjpeg-dev \
  libfreetype6-dev libgd-dev unixodbc-dev libpq-dev \
  psmisc fontconfig inotify-tools python3 python3-dev python3-pip python3-venv \
  postgresql-client default-mysql-client redis-tools ripgrep bubblewrap
# gh and Docker come from Docker's base image.
command -v gh
command -v docker
version=2026.5.2
case "$(uname -m)" in
  x86_64) arch=x64; checksum=cdf616b3d8554bece574cb1a5c0f19cc0f551dffbecf66037df1cc06569a42ef ;;
  aarch64|arm64) arch=arm64; checksum=a746ad85fe8a7b62a6c72939da5fb4231074fd16c482f6334a598bd92926f41e ;;
  *) echo 'Unsupported architecture' >&2; exit 1 ;;
esac
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "https://github.com/jdx/mise/releases/download/v$version/mise-v$version-linux-$arch.tar.gz" -o "$tmp/mise.tar.gz"
printf '%s  %s\n' "$checksum" "$tmp/mise.tar.gz" | sha256sum -c -
tar -C "$tmp" -xzf "$tmp/mise.tar.gz" mise/bin/mise
install -m 755 "$tmp/mise/bin/mise" /usr/local/bin/mise
