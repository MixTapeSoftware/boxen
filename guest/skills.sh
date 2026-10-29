#!/usr/bin/env bash
# Every skill on MixTapeSoftware/skills' main branch, such as botfight, for
# Claude Code, Codex and Grok. The skills float with main, as they did when
# the image baked them in.
set -euo pipefail
source /etc/boxen/env.sh
src="$HOME/.local/share/boxen/skills"
if [[ -d "$src/.git" ]]; then
  git -C "$src" pull --ff-only -q
else
  mkdir -p "${src%/*}"
  git clone -q --depth 1 https://github.com/MixTapeSoftware/skills.git "$src"
fi
bash /usr/local/share/boxen/skills-install.sh "$src" botfight
