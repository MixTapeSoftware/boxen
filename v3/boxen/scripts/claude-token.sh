#!/usr/bin/env bash
# Runs as the agent user after Docker's Claude mixin seeds ~/.claude/settings.json.
# When a per-sandbox anthropic secret is bound (SBX_CRED_ANTHROPIC_MODE=apikey),
# the proxy's placeholder reaches Claude Code through the apiKeyHelper the mixin
# seeds, which sends it as an API key; Anthropic rejects a subscription token
# there. Drop the helper and hand the placeholder over as CLAUDE_CODE_OAUTH_TOKEN
# instead, so it goes out as a Bearer token the claude-token mixin has the proxy
# swap. --force skips the mode check: bxn auth claude runs it after binding a
# token to a sandbox that exists already.
set -euo pipefail
source /etc/boxen/env.sh 2>/dev/null || true
if [[ "${1:-}" != --force && "${SBX_CRED_ANTHROPIC_MODE:-none}" != apikey ]]; then exit 0; fi
settings="$HOME/.claude/settings.json"
if [[ -s "$settings" ]]; then
  tmp="$(mktemp "$HOME/.claude/settings.XXXXXX.tmp")"
  trap 'rm -f "$tmp"' EXIT
  jq 'del(.apiKeyHelper)' "$settings" > "$tmp"
  mv "$tmp" "$settings"
  trap - EXIT
fi
# The placeholder is not a secret; the proxy swaps it per request.
umask 077
dir="$HOME/.config/boxen"; file="$dir/env.sh"
mkdir -p "$dir"; touch "$file"
grep -v '^export CLAUDE_CODE_OAUTH_TOKEN=' "$file" > "$file.tmp" || true
printf 'export CLAUDE_CODE_OAUTH_TOKEN=proxy-managed\n' >> "$file.tmp"
mv "$file.tmp" "$file"
