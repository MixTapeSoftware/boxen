#!/usr/bin/env bash
# The workload's command. Docker's agent mixins install an agent but cannot
# set the command, so BOXEN_AGENT, set at create, picks what starts. The
# mixins put their environment in /etc/profile.d, which a login shell reads.
profile="${BOXEN_PROFILE:-/etc/profile}"
env_file="${BOXEN_ENV_FILE:-/etc/boxen/env.sh}"
if [[ -r "$profile" ]]; then . "$profile"; fi
if [[ -r "$env_file" ]]; then . "$env_file"; fi
case "${BOXEN_AGENT:-shell}" in
  claude) exec claude --dangerously-skip-permissions "$@" ;;
  codex) exec codex --dangerously-bypass-approvals-and-sandbox "$@" ;;
  grok) exec grok --yolo --no-auto-update "$@" ;;
  shell) exec bash -l "$@" ;;
  *) echo "boxen: BOXEN_AGENT=$BOXEN_AGENT is not claude, codex, grok or shell" >&2; exit 64 ;;
esac
