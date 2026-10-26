#!/usr/bin/env bash
# Each sandbox signs its coding agent in to your subscription on its own; no
# key comes from the host. Run as the agent user by boxen.
#   status  prints the agent's name; exit 0 when nothing is needed, 10 when
#           the agent should sign in
#   login   the agent's own sign-in, which works without a local browser.
#           Claude has none here: its token is bound on the host (bxn auth
#           claude), since a /login inside the sandbox would be captured by
#           the proxy as a host-wide login shared by every sandbox.
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
      claude) echo 'boxen: Claude signs in with a token from the host: bxn auth claude NAME' >&2; exit 1 ;;
      # Device auth: the usual callback to localhost cannot reach a sandbox.
      codex) exec codex login --device-auth ;;
      *) echo "boxen: the $agent workload has no subscription sign-in" >&2; exit 1 ;;
    esac ;;
  *) echo 'Usage: agent-login.sh status|login' >&2; exit 2 ;;
esac
