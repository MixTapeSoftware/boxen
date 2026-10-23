#!/usr/bin/env bash
# Runs as root at build time. Links the skills Boxen ships into the
# system-wide skill folders Claude Code and Codex read, outside ~/.claude so
# no agent mixin's files are touched.
set -euo pipefail
source="${BOXEN_SKILLS_SRC:-/usr/local/share/boxen/skills}"
for target in "${BOXEN_CLAUDE_SKILLS:-/etc/claude-code/.claude/skills}" "${BOXEN_CODEX_SKILLS:-/etc/codex/skills}"; do
  mkdir -p "$target"
  ln -sfn "$source/botfight" "$target/botfight"
done
test -f "$source/botfight/SKILL.md"
