# Working on Boxen

Boxen is a Bash launcher for Docker Sandboxes (`sbx`): it creates sandboxes
for coding agents, with Boxen's tools and plugins as kits. The README covers
what it does; this file is what an agent changing it needs to know.

## Before you push

Run `bash tests/run.sh`. It checks every script's syntax and runs the Python
tests; everything must pass. Set `TEST_BASH` to a Bash 3.2 executable to run
the launcher's tests with it.

The host gates (`tests/host/*-gate.sh`, `tests/workload-smoke.sh`) create
real sandboxes. They need `sbx` and Docker on the host and do not work inside
a sandbox; leave them to the user and say which ones a change needs.

## Rules

- The launcher (`boxen`, `install`, `lib/`) and the host scripts run on macOS's
  Bash 3.2: no associative arrays, no `${var,,}`, and guard empty arrays under
  `set -u` with `${list[@]+"${list[@]}"}`.
- Pinned downloads are checked with `sha256sum -c`; never `@latest` or
  `releases/latest`.
- No credential, auth key or token goes in a kit, Dockerfile, script, log or
  command argument.
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
