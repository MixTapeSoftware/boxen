#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HOME/.local/bin"
curl -fsSL https://x.ai/cli/install.sh | GROK_BIN_DIR="$HOME/.local/bin" bash
