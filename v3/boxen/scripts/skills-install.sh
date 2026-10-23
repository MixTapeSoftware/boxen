#!/usr/bin/env bash
# Runs as root at build time. Links every skill from the skills repository,
# and gh stack's from its pinned checkout, where each agent reads skills,
# outside ~/.claude so no agent mixin's files are touched: Claude Code's
# system-wide folder, and ~/.agents/skills, which Codex and Grok both read.
set -euo pipefail
sources="${BOXEN_SKILLS_SRC:-/usr/local/share/boxen/skills /usr/local/share/boxen/gh-stack/skills}"
home="${BOXEN_AGENT_HOME:-/home/agent}"
owner="${BOXEN_AGENT_OWNER:-1000:1000}"
claude="${BOXEN_CLAUDE_SKILLS:-/etc/claude-code/.claude/skills}"
mkdir -p "$claude" "$home/.agents/skills"
for source in $sources; do
  for skill in "$source"/*/; do
    skill="${skill%/}"
    [[ -f "$skill/SKILL.md" ]] || continue
    name="$(basename "$skill")"
    ln -sfn "$skill" "$claude/$name"
    ln -sfn "$skill" "$home/.agents/skills/$name"
  done
done
# The agent may add skills of its own there.
chown -R -h "$owner" "$home/.agents"
for name in botfight gh-stack; do test -f "$claude/$name/SKILL.md"; done
