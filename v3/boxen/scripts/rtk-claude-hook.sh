#!/usr/bin/env bash
# Docker's agent mixin seeds ~/.claude/settings.json at create; this runs after
# it and adds RTK's PreToolUse command, keeping every other hook and setting.
set -euo pipefail
source /etc/boxen/env.sh 2>/dev/null || true
settings="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[[ -s "$settings" ]] || printf '{}\n' > "$settings"
tmp="$(mktemp "$HOME/.claude/settings.XXXXXX.tmp")"
trap 'rm -f "$tmp"' EXIT
jq '
  def without_rtk: map(.hooks |= map(select(.command != "rtk hook claude"))) | map(select((.hooks | length) > 0));
  .hooks.PreToolUse = ((.hooks.PreToolUse // []) | without_rtk)
    + [{"matcher": "Bash", "hooks": [{"type": "command", "command": "rtk hook claude"}]}]
' "$settings" > "$tmp"
mv "$tmp" "$settings"
trap - EXIT
