#!/usr/bin/env bash
# Grok Build. xAI's installer floats, like the cubic and RTK installers.
set -euo pipefail
source /etc/boxen/env.sh
mkdir -p "$HOME/.local/bin"
curl -fsSL https://x.ai/cli/install.sh | GROK_BIN_DIR="$HOME/.local/bin" bash
grok --version
