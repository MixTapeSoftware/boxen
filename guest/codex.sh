#!/usr/bin/env bash
# Codex, for a Sprite image that lacks it; Sprites ship it.
set -euo pipefail
source /etc/boxen/env.sh
npm install --global @openai/codex
codex --version
