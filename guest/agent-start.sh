#!/usr/bin/env bash
# agent-start.sh [ARGS...]      the agent chosen at create, in /workspace, with
#                               ARGS; a login zsh for a shell Sprite
# agent-start.sh --shell [LINE] a login zsh in /workspace, or LINE run by one
# bxn run and bxn shell run it, with a terminal when they have one.
set -uo pipefail
if [[ -r /etc/boxen/env.sh ]]; then source /etc/boxen/env.sh; fi
cd /workspace 2>/dev/null || cd "$HOME"
if [[ "${1:-}" == --shell ]]; then
  shift
  if [[ $# -gt 0 ]]; then exec zsh -lc "$1"; fi
  exec zsh -l
fi
case "${BOXEN_AGENT:-shell}" in
  claude) exec claude --dangerously-skip-permissions "$@" ;;
  codex) exec codex --dangerously-bypass-approvals-and-sandbox "$@" ;;
  grok) exec grok --yolo --no-auto-update "$@" ;;
  shell) exec zsh -l "$@" ;;
  *) echo "boxen: BOXEN_AGENT=$BOXEN_AGENT is not claude, codex, grok or shell" >&2; exit 64 ;;
esac
