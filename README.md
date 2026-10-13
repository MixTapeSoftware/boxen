# AgentSBX

Development sandboxes for coding agents on **local Docker Sandboxes**, with a
shell by default and optional Claude, Codex, or Grok workloads. Docker owns the
VM, network policy, credential proxy, and private Docker Engine. This project
supplies the `agbx` launcher, development tools as kits, shell configuration, and
Tailscale integration.

Requires SBX **0.47.0 or newer**, Docker sign-in, and a host supported by
[Docker Sandboxes](https://docs.docker.com/ai/sandboxes/install/). Linux needs
working KVM access; running inside a VM requires nested virtualization. The host
launcher uses Bash 3.2 and standard Unix tools; `kill-all` and `update-all` also
need jq. Python and Go are only needed for development tests. Kits live in this
directory and are not published to a registry.

## Start

~~~bash
sbx login
./install                 # Links agbx into ~/.local/bin; offers Chadmux
agbx doctor

# Choose an agent and kits, then copy the current directory into a new sandbox.
cd /path/to/project
agbx create my-project
agbx my-project      # Open a shell

# Copy another directory, or start empty.
agbx create my-project -p /path/to/project
agbx create scratch --no-copy

# A native agent entrypoint with the same tools.
agbx create codex-project --agent codex
agbx run codex-project
~~~

Creation stays detached so preview servers continue after closing your terminals.
Stop with `stop`; reconnect with `shell` or `run`. Files persist. Commands that
take a name check that the sandbox exists first, so a mistyped name never
creates a sandbox; only `create` does.

Each sandbox gets 4 CPUs (or fewer on a smaller host) and 4 GiB unless you pass
`--cpus` and `--memory`, or set `AGBX_CPUS` and `AGBX_MEMORY`. Every
sandbox is a microVM that holds its memory. On Linux, `create` refuses to start
one when available memory is below its size plus 1 GiB; a concurrent test
microVM once exhausted the validation host. `AGBX_SKIP_MEMORY_CHECK=1`
skips the check.

On first creation, SBX may ask for a network preset and approval of declared
credential destinations. Balanced is its default-deny development preset. The
kits add their own download/API hosts; they never enable allow-all. A destination
binding does not provide a credential. Configure credential sources separately.

## Commands

| Command | Short form | What it does |
|---|---|---|
| `create NAME [DIRECTORY]` | `init`, `-i` | Create a sandbox; see below |
| `NAME`, `shell [--with-sudo] NAME [COMMAND...]` | `-s` | Open zsh, or run a command |
| `run NAME [-- ARGS...]` | | Attach to the sandbox's agent |
| `exec NAME COMMAND [ARGS...]` | | Run a command |
| `net NAME [-b ADDR\|-H HOST] [-l] [-r PORT] [PORT\|HOST:SANDBOX ...]` | `-n` | Publish ports on the host through `sbx ports`; `-r all` is not supported |
| `env NAME VAR` | `-e` | Set a variable; prompts without echoing |
| `stop NAME`, `kill-all` | `kill`, `-k`, `-ka` | Stop one sandbox, or every running agbx sandbox |
| `delete NAME` | `-d` | Remove it, after sbx asks to confirm |
| `update NAME`, `update-all`, `cron install [HOUR]\|remove\|status` | `-u`, `-ua` | `apt-get upgrade` as root, on demand or nightly |
| `status [--once]` | | `sbx tui`, or `sbx ls` once |

`auth`, `tailscale`, `check`, `validate` and `doctor` are described below, and
`agbx --help` lists every option. Updates live in the container, so a
recreate such as `sbx kit add` starts again from the image.

## Choosing kits

In a terminal, `create` opens a selector: choose one agent and any kits. Arrow
keys or j/k move, Space chooses, Enter creates, and q quits without creating
anything. Only Matt Pocock Skills starts selected, and these flags pre-select
more: `--agent NAME`, `--claude`, `--codex`, `--grok`, `--tailscale`,
`--supabase-serve`, `--gh-token`, `--1pass`, `--cubic`, `--matt-pocock-skills`.

`--plugins` chooses without the selector, as do `--no-tui` and non-interactive
runs:

~~~bash
agbx create web --tailscale --supabase-serve --gh-token --no-tui
agbx create small --plugins fzf-bat,just,gh-auth
agbx create everything --plugins all
agbx create base --plugins none
agbx create preview --dry-run
~~~

The core kit always supplies build libraries and the development shell.
Supabase Serve automatically selects Tailscale. Each sandbox runs one agent
workload; create a second sandbox for another agent.

## Workspace behavior

| Option | Behavior |
|---|---|
| Default | Copies the current directory (or `-p PATH`) once into `/workspace`, including uncommitted files and `.git`. No host bind mount. |
| `--no-copy` | Empty `/workspace`. Clone or create a repository inside it. |
| `--mode mount` | Explicit read/write host workspace mount. |
| `--mode clone` | SBX's private Git clone workflow; requires a host Git worktree. |

Copied and empty workspaces live on a 20 GiB kit volume. `sbx kit add` recreates
the container and keeps only kit volumes, bind mounts and clone working trees;
on the volume, the copy and your uncommitted work survive it. Everything else
outside volumes, such as packages from `update`, is rebuilt from the image.

Copy mode has no automatic synchronization back to the host. Use Git or sbx cp
to bring work out. The launcher refuses to copy your home directory or `/`.
When the directory holds `.env` files, it lists them and asks before copying
(or mounting); `--ack-env` skips the question. From macOS, the copy omits
AppleDouble `._` files and extended attributes.

The copy skips folders the sandbox rebuilds, which are usually most of its
bytes and are often built for the host's platform rather than Linux:
`node_modules`, Python virtualenvs and caches, framework caches such as `.next`,
and `deps`, `_build` or `target` beside `mix.exs` or `Cargo.toml`. Run your
install step in the sandbox afterwards, or pass `--copy-all` to copy them anyway.
`create` and `--dry-run` print the copy's size and the skipped folders; with
`pv` installed, `create` also shows a progress bar.

A large copy takes a while because every byte crosses into the sandbox's
microVM and is written to its own disk. `--mode mount` avoids the
copy, at the cost of sharing your files read-write.

### Host mounts

By default nothing from the host is mounted into a sandbox, whichever agent it
runs: the workspace is copied, and the sbx shared skills store is off (sbx's
own default links it in read-only). Opt in per sandbox:

| Option | Shares with the host |
|---|---|
| `--mode mount` | The workspace directory, read-write |
| `--mode clone` | The workspace repository, read-only, plus a Git remote back to the host |
| `--skills readonly` / `--skills readwrite` | The sbx skills store |

`--dry-run` lists the host mounts a create would add. `sbx mount` can add one
to a running sandbox later. sbx's `ssh.agentForwardingEnabled` setting lets
SSH clients forward an SSH agent into sandboxes; agbx connects with
`sbx exec` instead. To rule it out entirely:
`sbx settings set ssh.agentForwardingEnabled false`.

The launcher forwards host Git name/email when configured. It does not copy Git
credentials, agent login files, SSH private keys, or your host home directory.

## Sudo

Docker's images give the agent user standing passwordless sudo. agbx
removes it, and fails creation if it cannot. For root, open a
session with `./agbx shell --with-sudo NAME`: it adds a `_sudo` group to
that session only. Agents are told to ask you instead of using sudo.

## Kits

| Kit | What it installs |
|---|---|
| Docker | Native private Docker Engine and Compose |
| Chromium/Playwright | Playwright 1.61.1 with Chromium; an additional **matched** Chrome for Testing/ChromeDriver pair for Wallaby |
| fzf + bat | mise-managed tools, f and gdiff shell helpers |
| Claude Code | Docker's Claude workload; derived workload adds separate RTK settings |
| Codex | Docker's Codex workload |
| Grok Build | Local workload based on Docker's community kit, inheriting shell defaults |
| just | mise-managed just |
| Glow | mise-managed Glow |
| mermaid-ascii | Version 1.4.0, architecture-specific release |
| Overmind | Go-installed CLI and its tmux runtime dependency |
| cubic | Official user-level installer; log in on first use |
| nvChad / Chadception | Your chadfennell/nvChad config, Neovim, tree-sitter parsers, and six Mason LSPs |
| RTK | Version 0.51.0, Codex hooks, and a separate Claude settings file |
| Matt Pocock Skills | Sandbox-local shared skills for Claude, Codex, and Grok |
| Tailscale | Userspace daemon, per-sandbox identity, persistent state volume |
| Supabase Serve | The same seven HTTPS routes |
| GitHub Auth | Native SBX credential injection plus Git helper/identity configuration |
| 1Password | Host op:// secret sources; op CLI also installed in the guest |

The core kit includes mise, Node 22, Go, zsh, Oh My Zsh with your dpoggi theme
and autosuggestions, GitHub CLI, database clients, and common build
dependencies. Shared host skills are disabled when creating these environments;
skill installation stays inside each sandbox.

Tools are pinned. Downloads of pinned binaries (mise, Tailscale, the 1Password
CLI, Chrome for Testing, Neovim, mermaid-ascii) are checked against SHA-256
sums. The Grok, cubic and RTK installers come from their vendors' scripts.

Network rules for hosts most kits share (GitHub, Ubuntu, Node, Go) live in the
core kit, which every sandbox has; each optional kit lists only its own extras.
Rules last for the sandbox's lifetime, including install-time hosts such as
`storage.googleapis.com`.

These are [v2 kits](https://docs.docker.com/ai/sandboxes/customize/kits-v2/) because
Docker's built-in agents use v2. Do not mix them with v3 kits. To use kits directly,
add kits/core (and kits/workspace for a mountless sandbox) before optional tool
kits. The launcher handles ordering.

Absolute /home/agent paths in the descriptors refer to the sandbox filesystem.
Host kit paths are calculated from the launcher's location, so the checkout can
live anywhere; there is no dependency on this checkout's /workspace location.

Kits are chosen per sandbox in the selector, so they are not packaged as a
[kit set](https://docs.docker.com/ai/sandboxes/customize/#kit-sets), which
fixes one combination behind a single registry reference. They stay individual
mixins, shareable through Git or an OCI registry, with this launcher selecting
them. Local creation uses no Docker Cloud sandbox and uploads none of these kit
files.

## Host setup and Chadmux

`./install` links `agbx` into `~/.local/bin`; the launcher follows the link
back to this checkout's kits. It then offers Chadmux, Chad's opinionated tmux
config, with TPM plugins for the Dracula theme, tmux-yank and
vim-tmux-navigator. `./install --chadmux` installs it without asking, and
`--no-chadmux` skips the question.

Chadmux installs only on a host that has git and tmux and no tmux config of its
own: an existing `~/.tmux.conf`, `~/.config/tmux` or `$XDG_CONFIG_HOME/tmux` is
never moved, replaced or linked over. It follows Chadmux's main branch. If the
TPM clone fails, run `./install --chadmux` again to finish. Chadmux is a host
setup; sandboxes do not get it, and its automatic pane labels do not recognize
sbx sessions yet.

## Credentials

No credential comes from the host by default. Each sandbox gets its own.

### Agent sign-in

Claude Code and Codex sandboxes each sign in to your subscription separately,
inside the sandbox. `create` offers the sign-in when it finishes, and so does
entering a sandbox that is not signed in (`agbx NAME`, `agbx shell NAME`,
`agbx run NAME`). Claude Code uses `claude auth login --claudeai`; Codex uses
`codex login --device-auth`, a code you enter in your browser, since its usual
`localhost` callback cannot reach a sandbox. Answer n to skip; the offer comes
back next time.

The login lives inside the sandbox, where the agent can read it, and goes away
with the sandbox. A container recreation such as `sbx kit add` also drops it;
the next entry offers the sign-in again.

Do not store `anthropic` or `openai` secrets host-wide with `sbx secret set`:
Docker's Claude and Codex workloads then use that one credential in every
sandbox instead of the sandbox's own sign-in. `create` and `doctor` warn when
one exists; remove it with `sbx secret rm anthropic` (or `openai`). Grok uses
an xAI API key; `agbx env NAME XAI_API_KEY` stores one for that sandbox only.

### Plugin keys

In a terminal, `create` asks for the keys its plugins need before it starts
provisioning. Leave any blank to skip it.

| Plugin | Asks for | Where it goes |
|---|---|---|
| gh-auth | A fine-grained GitHub token (Contents read/write, Metadata read-only) | An sbx secret scoped to this sandbox; the proxy injects it and the sandbox sees a placeholder |
| 1pass | A 1Password service account token | Inside the sandbox, for `op`; the agent can read it |
| tailscale | A tagged auth key, and a dev port for :443 unless Supabase Serve is selected | Straight to the sandbox's tailnet join; not stored |

Without a terminal, or after skipping, add them later:

~~~bash
agbx auth github my-project                     # paste a fine-grained token, or pipe one in
op read 'op://Work/GitHub/fine-grained-token' | agbx auth github my-project
agbx auth github my-project --from-gh           # the host gh token, with every scope gh has
agbx env my-project OP_SERVICE_ACCOUNT_TOKEN
agbx tailscale join my-project
agbx auth 1password my-project github 'op://Work/GitHub/token'   # host op:// reference
~~~

Sandbox-scoped sbx secrets are removed with the sandbox. `env` stores known API
keys (such as `XAI_API_KEY`) as sandbox-scoped sbx secrets; other variables
live in `~/.config/agbx/env.sh` inside the sandbox, where the agent can read
them. For other APIs, see
[SBX custom secrets](https://docs.docker.com/ai/sandboxes/configuration/credentials/).

## Tailscale and previews

Join through the browser/device flow:

~~~bash
./agbx tailscale join my-project
./agbx tailscale status my-project
~~~

Or pipe a tagged auth key directly from a secret manager:

~~~bash
op read 'op://Development/Tailscale/auth-key' |
  ./agbx tailscale join my-project --auth-key-stdin
~~~

The key travels on stdin into a temporary guest file with private permissions.
Tailscale receives that file's path; the file is removed afterward. No auth
key belongs in a kit, CLI argument, image, shell profile, or environment file.

**A joined sandbox reaches whatever your tailnet ACLs allow, outside sbx's
network policy.** Use a tagged key whose ACLs grant only what the sandbox
needs, and no exit nodes or Funnel. The node has no operator, so the agent
cannot change its settings; `join`, `serve` and `status` run as root.

~~~bash
./agbx tailscale serve my-project 5173
./agbx tailscale serve my-project supabase
~~~

| Tailnet HTTPS port | Guest HTTP port | Service |
|---|---|---|
| 443 | 3000 | Main app |
| 4410 | 3010 | Secondary app |
| 4431 | 3001 | Secondary app |
| 5432 | 54321 | Supabase API, **not Postgres** |
| 5433 | 54323 | Supabase Studio |
| 5434 | 54324 | Mailpit/Inbucket |
| 8443 | 8000 | Kong |

With Supabase Serve selected, joining through the wrapper applies the preset
once; tailscaled keeps serve config in its state volume, so it survives
restarts. The preset owns :443, so a single-port `serve` is refused while it is
selected; run the app on port 3000. The preset configures routes, but does not
install or start Supabase. Enable Tailscale HTTPS when requested by Tailscale's
own flow.

Each environment has a separate node identity named after its sandbox. State
lives on the dedicated /var/lib/tailscale kit volume. Do not export an enrolled
environment as an image until you have verified that your export excludes this
volume; this wrapper deliberately has no template-export command.

Userspace networking avoids a tunnel device and uses a local SOCKS5 listener for
outgoing tailnet connections. For an individual command:

~~~bash
curl --proxy socks5h://127.0.0.1:1055 http://other-machine:3000
~~~

Keep Docker's HTTP_PROXY/HTTPS_PROXY values intact so credential injection
continues working. Userspace mode does not provide transparent kernel routing.
Direct peer UDP is not enabled by these kits; relay performance depends on the
host network and SBX policy.

~~~bash
./agbx exec my-project tail /var/log/agbx/tailscaled.log
~~~

## RTK and editor details

RTK's Codex setup writes hooks.json and instructions, leaving Docker's managed
config.toml alone. For Claude, the derived workload passes the separate
/home/agent/.config/agbx/claude-rtk.json file through --settings. Pass the
same option when launching Claude manually. Grok can use the RTK CLI explicitly;
this project does not claim an automatic Grok hook.

NvChad is pinned to your configuration revision
c0e1543a7a64c8db877df02fc7decfb0a9e07ecb, with Neovim v0.12.6. An existing
Neovim configuration is preserved in a sibling backup before replacement.
Parser installation failures fail creation; `check` confirms the six Mason
language servers.

## Verify and develop

~~~bash
./agbx validate                 # Docker's actual kit validator; requires login
./agbx check my-project         # Tool/browser/config checks inside the guest

python3 -m pip install -r tests/requirements.txt
bash tests/run.sh                    # Syntax and isolated host CLI tests
bash tests/validate-upstream.sh      # Docker's pinned v2 parser, no Docker login

# Native workload and workspace-copy checks; run sequentially with other VMs stopped.
bash tests/workload-smoke.sh grok
bash tests/workload-smoke.sh claude
bash tests/workload-smoke.sh codex
~~~

Set TEST_BASH to a Bash 3.2 executable to exercise the host CLI with it.
Tests never use personal credentials. Runtime checks do not authenticate
agents, join a tailnet, or read a vault automatically.

The code suite includes isolated Tailscale tests using fake commands for route
arguments, timeouts, and auth-file cleanup. Further live Tailscale smoke
validation is skipped for this prototype at the user's request.

Each workload check creates a disposable sandbox capped at 1 GiB and two CPUs.
It refuses concurrent sandboxes and, on Linux, requires at least 3 GiB available
memory before starting. It also checks that the agent has no standing sudo,
that `--with-sudo` works, and that the copied workspace survives `sbx kit add`.
Successful test sandboxes are removed; failed ones are stopped if SBX retained
them. The disk check requires 3 GiB free with a cached base image or 6 GiB
without one. Logs stay under ignored local/; a lock left by a dead run is
reclaimed.

See [validation notes](docs/validation.md) for what was actually exercised.
