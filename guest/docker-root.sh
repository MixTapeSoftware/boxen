#!/usr/bin/env bash
# The docker plugin, as root: Docker Engine, Compose and Buildx from Ubuntu's
# archive, and the Sprite's user in the docker group. docker-service.sh then
# starts dockerd. Needs the privileged profile, which the plugin asks for.
# The argument is the user.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io docker-compose-v2 docker-buildx
if [[ -n "${1:-}" ]]; then usermod -aG docker "$1"; fi
# Fly's guide (/.sprite/docs/docker.md) runs Docker on overlay2 rather than
# Docker 29's default containerd image store; keep any other settings.
mkdir -p /etc/docker
if [[ -s /etc/docker/daemon.json ]]; then
  jq '."storage-driver" = "overlay2"' /etc/docker/daemon.json > /etc/docker/daemon.json.new
  mv /etc/docker/daemon.json.new /etc/docker/daemon.json
else
  printf '{"storage-driver": "overlay2"}\n' > /etc/docker/daemon.json
fi
