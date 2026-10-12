#!/usr/bin/env bash
set -euo pipefail
source /etc/sandbox-persistent.sh
curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/v0.51.0/install.sh | RTK_VERSION=v0.51.0 sh
# This version writes hooks.json and AGENTS.md, without changing config.toml.
rtk init --global --codex
# Claude's Docker-managed settings.json must remain untouched. Our derived
# Claude workload loads this separate settings file through --settings.
mkdir -p "$HOME/.config/agent-sbx"
cat > "$HOME/.config/agent-sbx/claude-rtk.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{"type": "command", "command": "rtk hook claude"}]
    }]
  }
}
EOF
rtk --version
