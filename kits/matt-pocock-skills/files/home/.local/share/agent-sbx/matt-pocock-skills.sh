#!/usr/bin/env bash
set -euo pipefail
source /etc/sandbox-persistent.sh
# Shared host skills are disabled by our launcher; these remain sandbox-local.
npx --yes skills@1.7.2 add mattpocock/skills \
  --global --agent claude-code codex --skill '*' --yes
