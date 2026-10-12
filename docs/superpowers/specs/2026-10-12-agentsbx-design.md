# AgentSBX

A standalone project that provisions development sandboxes for coding agents on
local Docker Sandboxes, through the `agbx` command.

## Implementation choices

- Use Bash 3.2 for the host CLI and installer. Use supported v2 kits because
  Docker's built-in shell, Claude, and Codex workloads are v2.
- Delegate VM lifecycle and credential proxying to `sbx`; do not build another
  proxy, daemon, or plugin API.
- Keep short command aliases (`-s`, `-i`, `-n`, `-e`, `-k`, `-ka`, `-d`, `-u`,
  `-ua`) and let a bare sandbox name open a shell. Commands that take a name
  check that the sandbox exists, so a typo never reaches `sbx run`, which
  creates missing sandboxes.
- Choose kits per sandbox in an interactive selector, with flags to pre-select
  and `--plugins` or `--no-tui` for scripts. Because combinations vary per
  sandbox, the kits are not packaged as a fixed kit set.
- Start with a shell workload. Select Claude or Codex through their built-ins;
  include a local Grok workload based on Docker's community kit. One agent per
  sandbox; agents stay independent of the common provisioning mixin.
- Core provisioning supplies build dependencies, mise, Node, Go, GitHub CLI,
  zsh/Oh My Zsh, and common shell paths, plus the network hosts most kits
  share. Tool installers run as UID 1000; system installation runs as root.
  Pin tool versions and check pinned downloads against SHA-256 sums.
- Remove the agent's standing sudo; `shell --with-sudo` grants it to one
  session.
- Preserve Chromium's `google-chrome` and `chromedriver` compatibility. Match
  browser and driver versions and handle amd64/arm64 explicitly.
- GitHub authentication and 1Password credential delivery use SBX's host secret
  sources, with a fine-grained GitHub token by default. Support optional
  in-sandbox `op` separately; never copy service tokens into images.
- Use a per-sandbox userspace tailscaled with a startup hook and no operator.
  Join interactively after creation or read an auth key from stdin into a
  temporary private guest file; never place a key in arguments, generated
  specs, logs, or environment files. Keep state, including serve config, on a
  dedicated kit volume. Apply single-port HTTPS or the seven Supabase Serve
  mappings through the wrapper. Keep Docker's HTTP proxy settings intact;
  outbound tailnet access is explicitly through Tailscale's SOCKS proxy.
- Mount nothing from the host by default. Copy the workspace once onto a kit
  volume so container recreation keeps it; `--mode mount`, `--mode clone` and
  `--skills` opt in to host mounts. Configuration and kit source are never
  mounted writable into the sandbox by default.
- Start created environments detached so previews survive closed terminals.
- A host installer links the launcher into `~/.local/bin` and offers Chadmux,
  an opinionated tmux config, without ever replacing an existing tmux config.
- Keep documentation, the kit list, meaningful CLI/lifecycle tests, native kit
  validation, and guest smoke checks in this directory.

## Validation and limits

Validate descriptors with the actual SBX CLI, check Bash syntax, exercise wrapper
argument handling/secret transport/dependency expansion with a fake SBX command,
and test actual installers in disposable Docker containers where practical.
Attempt a real SBX environment if this host has usable KVM and Docker login.
Do not imply runtime validation if nested virtualization or authentication blocks
it. Authenticated agent inference, live vault access, and tailnet joining require
the user's own credentials and are distinct from installation smoke tests.
