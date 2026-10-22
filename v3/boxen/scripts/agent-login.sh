#!/usr/bin/env bash
# Each sandbox signs its coding agent in to your subscription on its own; no
# key comes from the host. Run as the agent user by boxen.
#   status  exit 0 when nothing is needed, 10 when the agent should sign in
#   login   the agent's own sign-in, which works without a local browser
set -uo pipefail
if [[ -r /etc/boxen/env.sh ]]; then source /etc/boxen/env.sh; fi
agent="${BOXEN_AGENT:-shell}"
case "${1:-}" in
  status)
    case "$agent" in
      claude) claude auth status --json >/dev/null 2>&1 || exit 10 ;;
      codex) codex login status >/dev/null 2>&1 || exit 10 ;;
    esac
    exit 0 ;;
  login)
    case "$agent" in
      claude) exec claude auth login --claudeai ;;
      # Device auth: the usual callback to localhost cannot reach a sandbox.
      codex) exec codex login --device-auth ;;
      *) echo "boxen: the $agent workload has no subscription sign-in" >&2; exit 1 ;;
    esac ;;
  *) echo 'Usage: agent-login.sh status|login' >&2; exit 2 ;;
esac
