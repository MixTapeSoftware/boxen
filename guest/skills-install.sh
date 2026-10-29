#!/usr/bin/env bash
# skills-install.sh SOURCE [REQUIRED...]: link every skill in SOURCE (a
# folder of SKILL.md folders) where each agent reads skills: ~/.claude/skills
# for Claude Code, and ~/.agents/skills, which Codex and Grok both read.
# Fails when a REQUIRED skill is missing. Runs as the Sprite's user.
set -euo pipefail
source="$1"; shift
claude="${BOXEN_CLAUDE_SKILLS:-$HOME/.claude/skills}"
shared="${BOXEN_SHARED_SKILLS:-$HOME/.agents/skills}"
mkdir -p "$claude" "$shared"
for skill in "$source"/*/; do
  skill="${skill%/}"
  [[ -f "$skill/SKILL.md" ]] || continue
  name="$(basename "$skill")"
  ln -sfn "$skill" "$claude/$name"
  ln -sfn "$skill" "$shared/$name"
done
for name in "$@"; do test -f "$claude/$name/SKILL.md" && test -f "$shared/$name/SKILL.md"; done
