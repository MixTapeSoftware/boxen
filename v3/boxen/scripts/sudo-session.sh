#!/bin/sh
# Installed as /usr/local/bin/boxen-sudo-session and run as root by
# boxen shell --with-sudo. Drops to agent with the _sudo group added for
# this session only.
set -eu
groups="$(id -G agent | tr ' ' ','),$(getent group _sudo | cut -d: -f3)"
export HOME=/home/agent USER=agent LOGNAME=agent
exec setpriv --reuid=1000 --regid=1000 --groups="$groups" --inh-caps=-all -- "$@"
