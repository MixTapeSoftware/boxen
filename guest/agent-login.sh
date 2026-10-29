#!/usr/bin/env bash
# Each Sprite signs its coding agent in to the teammate's own subscription.
# Run as the Sprite's user by bxn.
#   status  prints the agent's name; exit 0 when nothing is needed, 10 when
#           the agent should sign in
#   login   Codex's device sign-in, which needs no browser in the Sprite.
#           Claude Code signs in itself with /login when it starts.
set -uo pipefail
if [[ -r /etc/boxen/env.sh ]]; then source /etc/boxen/env.sh; fi
agent="${BOXEN_AGENT:-shell}"
case "${1:-}" in
  status)
    printf '%s\n' "$agent"
    case "$agent" in
      claude) claude auth status >/dev/null 2>&1 || exit 10 ;;
      codex) codex login status >/dev/null 2>&1 || exit 10 ;;
    esac
    exit 0 ;;
  login)
    case "$agent" in
      claude) echo 'boxen: start Claude Code with bxn run NAME and sign in with /login' >&2; exit 1 ;;
      # Device auth: the usual callback to localhost cannot reach a Sprite.
      codex) exec codex login --device-auth ;;
      *) echo "boxen: the $agent Sprite has no subscription sign-in" >&2; exit 1 ;;
    esac ;;
  *) echo 'Usage: agent-login.sh status|login' >&2; exit 2 ;;
esac
