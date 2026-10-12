#!/usr/bin/env bash
set -euo pipefail
source /etc/sandbox-persistent.sh
curl -fsSL https://cubic.dev/install | bash
# Running cubic may open interactive login. Check the executable only.
test -x "$HOME/.cubic/bin/cubic"
