#!/usr/bin/env bash
# Refreshes the repository's agent skills from the skills repository's main
# branch, then links every skill in .agents/skills for each agent. Codex reads
# .agents/skills itself; Claude Code reads .claude/skills and Grok
# .grok/skills. Skills that exist only here are kept. Run from anywhere:
#   bash scripts/sync-skills.sh
set -euo pipefail
repo="${BOXEN_SKILLS_REPO:-https://github.com/MixTapeSoftware/skills.git}"
root="${BOXEN_SKILLS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git clone --quiet --depth 1 --branch main "$repo" "$tmp/skills"
mkdir -p "$root/.agents/skills"
for skill in "$tmp"/skills/*/; do
  skill="${skill%/}"
  name="$(basename "$skill")"
  [[ -f "$skill/SKILL.md" ]] || continue
  rm -rf "$root/.agents/skills/$name"
  # No trailing slash: macOS cp would copy the folder's contents instead.
  cp -R "$skill" "$root/.agents/skills/$name"
  echo "synced $name"
done
for folder in .claude/skills .grok/skills; do
  mkdir -p "$root/$folder"
  # Drop links to skills that are gone, then link every skill there is.
  for link in "$root/$folder"/*; do
    if [[ -L "$link" && ! -e "$link" ]]; then rm -f "$link"; fi
  done
  for skill in "$root"/.agents/skills/*/; do
    [[ -d "$skill" ]] || continue
    name="$(basename "$skill")"
    ln -sfn "../../.agents/skills/$name" "$root/$folder/$name"
  done
done
