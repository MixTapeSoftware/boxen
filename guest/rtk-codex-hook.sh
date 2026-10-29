#!/usr/bin/env bash
# Runs as the Sprite's user at create, for a Codex Sprite with rtkplus.
set -euo pipefail
source /etc/boxen/env.sh 2>/dev/null || true
rtk init --global --codex
