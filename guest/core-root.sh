#!/usr/bin/env bash
# Base provisioning, as root: the apt packages every Sprite gets, mise, and
# the GitHub CLI. The Sprite already has git, curl, Node, Python and Go.
# The argument is the Sprite's user.
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
case "$(uname -m)" in
  x86_64)
    arch=x64; checksum=cdf616b3d8554bece574cb1a5c0f19cc0f551dffbecf66037df1cc06569a42ef
    gh_arch=amd64; gh_checksum=4c806978ffce1cec70853302a56d70ac6da4f19bae7adca4e1a8ab00633dd91d ;;
  aarch64|arm64)
    arch=arm64; checksum=a746ad85fe8a7b62a6c72939da5fb4231074fd16c482f6334a598bd92926f41e
    gh_arch=arm64; gh_checksum=ee32df2323c8847f5fac6cb6b4b69ca75828e9329a8f22f677021f7b3306ce63 ;;
  *) echo 'Unsupported architecture' >&2; exit 1 ;;
esac
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
version=2026.5.2
curl -fsSL "https://github.com/jdx/mise/releases/download/v$version/mise-v$version-linux-$arch.tar.gz" -o "$tmp/mise.tar.gz"
printf '%s  %s\n' "$checksum" "$tmp/mise.tar.gz" | sha256sum -c -
tar -C "$tmp" -xzf "$tmp/mise.tar.gz" mise/bin/mise
install -m 755 "$tmp/mise/bin/mise" /usr/local/bin/mise
gh_version=2.103.3
curl -fsSL "https://github.com/cli/cli/releases/download/v$gh_version/gh_${gh_version}_linux_$gh_arch.tar.gz" -o "$tmp/gh.tar.gz"
printf '%s  %s\n' "$gh_checksum" "$tmp/gh.tar.gz" | sha256sum -c -
tar -C "$tmp" -xzf "$tmp/gh.tar.gz"
install -m 755 "$tmp/gh_${gh_version}_linux_$gh_arch/bin/gh" /usr/local/bin/gh
gh --version
# zsh is the login shell of the user named as the first argument, so a
# console opens the configured shell.
if [[ -n "${1:-}" ]]; then chsh -s "$(command -v zsh)" "$1" || true; fi
