#!/usr/bin/env bash
# The docker plugin, as the Sprite's user: dockerd as a sprite-env service, so
# it comes back when a sleeping Sprite wakes. sprite-env is in /.sprite/bin,
# which sudo leaves off root's PATH, so this runs as the user, as the spike
# does; the service starts dockerd as root through sudo.
set -euo pipefail
# Ubuntu's docker.io has moved dockerd between /usr/sbin and /usr/bin.
dockerd="$(PATH="$PATH:/usr/sbin"; command -v dockerd)"
if ! sprite-env services get dockerd >/dev/null 2>&1; then
  sprite-env services create dockerd --cmd /usr/bin/sudo --args "-n,$dockerd" --no-stream
fi
# The docker group applies to new sessions only, so ask through sudo.
for _ in $(seq 1 30); do
  if sudo -n docker info >/dev/null 2>&1; then
    # A container proves more than a running daemon: networking and storage too.
    sudo -n docker run --rm --pull missing alpine true
    docker --version; docker compose version; exit 0
  fi
  sleep 1
done
echo 'docker: dockerd did not start; see /.sprite/logs/services/dockerd.log' >&2
exit 1
