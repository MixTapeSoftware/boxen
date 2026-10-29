#!/usr/bin/env bash
# The docker plugin, as root: Docker Engine, Compose and Buildx from Ubuntu's
# archive, the Sprite's user in the docker group, and dockerd as a sprite-env
# service, so it comes back when a sleeping Sprite wakes. Needs the
# privileged profile, which the plugin asks for. The argument is the user.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io docker-compose-v2 docker-buildx
if [[ -n "${1:-}" ]]; then usermod -aG docker "$1"; fi
# Services may run as the Sprite's user; sudo starts dockerd as root either way.
if ! sprite-env services get dockerd >/dev/null 2>&1; then
  sprite-env services create dockerd --cmd /usr/bin/sudo --args "-n,/usr/sbin/dockerd" --no-stream
fi
for _ in $(seq 1 30); do
  if docker info >/dev/null 2>&1; then docker --version; docker compose version; exit 0; fi
  sleep 1
done
echo 'docker: dockerd did not start; see /.sprite/logs/services/dockerd.log' >&2
exit 1
