#!/usr/bin/env bash
# Runs as the agent at create, after Docker's Codex mixin.
set -euo pipefail
source /etc/boxen/env.sh 2>/dev/null || true
rtk init --global --codex
