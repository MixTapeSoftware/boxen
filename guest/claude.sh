#!/usr/bin/env bash
# Claude Code, for a Sprite image that lacks it; Sprites ship it. Anthropic's
# installer floats, like the cubic and RTK installers.
set -euo pipefail
source /etc/boxen/env.sh
curl -fsSL https://claude.ai/install.sh | bash
claude --version
