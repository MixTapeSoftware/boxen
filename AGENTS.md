# Working on Boxen

Boxen is a Bash launcher for Fly.io Sprites: it creates a locked-down Sprite
per project, installs the plugins a teammate picks, clones the repository and
opens a shell or coding agent in it. The README covers what it does; this
file is what an agent changing it needs to know.

## Before you push

Run `bash tests/run.sh`. It checks every script's syntax and runs the Python
tests; everything must pass. Set `TEST_BASH` to a Bash 3.2 executable to run
the launcher's tests with it.

`tests/sprite/spike.sh` creates a real Sprite. It needs the `sprite` CLI
logged in to the team's Fly organization and does not work from inside a
Sprite; leave it to the user, and say when a change depends on what it
checks.

## Rules

- The launcher (`bxn`, `install`, `lib/`, `plugins/`) runs on macOS's Bash
  3.2: no associative arrays, no `${var,,}`, and guard empty arrays under
  `set -u` with `${list[@]+"${list[@]}"}`. `guest/` runs inside the Sprite,
  on Ubuntu's Bash.
- Plugins reach a Sprite only through `box_root`, `box_user`, `box_guest` and
  `box_set_env` in `lib/box.sh`, never `sprite` directly. A plugin is
  `plugins/ID.sh`, listed in install order in `plugins/plugins.tsv`, and
  declares every host it needs in `PLUGIN_EGRESS_HOSTS`.
- A Sprite is born unrestricted. Nothing may run in it before `lock_down` has
  set and read back its policies; a Sprite that fails lock-down is destroyed.
- Install system packages with `box_root` and everything else as the
  Sprite's user with `box_user`.
- Pinned downloads are checked with `sha256sum -c`; never `@latest` or
  `releases/latest`.
- No credential, auth key or token goes in a plugin, script, log, command
  argument or `--env` flag. Values travel on stdin.
- A commit message is one plain, imperative sentence.
- With `gh api`, write every request body, including GraphQL queries, to a
  JSON file and send it with `--input <file>.json`. Never use `-f` or `-F`:
  they mangle multi-line text and values that start with `@`.

## Skills

Agent skills live once, in `.agents/skills/<name>/SKILL.md`, which Codex
reads. `.claude/skills/` (Claude Code) and `.grok/skills/` (Grok) hold
symlinks to them. Don't edit the links by hand. To add or refresh skills, run
`bash scripts/sync-skills.sh`. It copies every skill from the `main` branch of
[MixTapeSoftware/skills](https://github.com/MixTapeSoftware/skills), keeps
skills that exist only here, and relinks them all for each agent. Commit
what it changes.
