# Boxen

Development sandboxes for coding agents on **Docker Sandboxes**, locally or in
Docker Cloud, with a shell by default and optional Claude, Codex or Grok. Docker
owns the VM, network policy, credential proxy and private Docker Engine. This
project supplies the `boxen` launcher, an image with every development tool baked
in, a few option kits, shell configuration and Tailscale integration.

Requires SBX **0.47.0 or newer**, Docker sign-in, Docker itself, running (sbx
builds the local [v3 kits](https://docs.docker.com/ai/sandboxes/customize/) with
it, for local and cloud sandboxes alike), and a host supported by
[Docker Sandboxes](https://docs.docker.com/ai/sandboxes/install/). Local sandboxes
on Linux need working KVM access; running inside a VM requires nested
virtualization. The host launcher uses Bash 3.2 and standard Unix tools;
`kill-all`, `update-all` and `create --cloud` also need jq, and cloud previews
need ssh. Python is only needed for development tests. Kits live in `v3/` and
are not published to a registry.

## Why sbx

Docker Sandboxes (`sbx`) runs each sandbox in its own microVM by default. A
microVM starts quickly, like a container, but gives the agent its own kernel
instead of sharing the host's, which makes it a stronger boundary than a
regular container. sbx also has kits, a kind of plugin that adds tools, setup
steps, network rules and credentials to a sandbox.

Boxen is a thin wrapper around sbx. It keeps one image with every tool baked
in, and a few small option kits, in this repository, so every new sandbox
starts from the same setup instead of being configured by hand.

## Start

~~~bash
sbx login
./install                 # Links boxen into ~/.local/bin; offers Chadmux
boxen doctor              # boxen doctor --cloud skips the KVM check

# Choose an agent and kits, then copy the current directory into a new sandbox.
cd /path/to/project
boxen create my-project
boxen my-project     # Open a shell

# Copy another directory, or start empty.
boxen create my-project -p /path/to/project
boxen create scratch --no-copy

# An agent with the same tools; boxen run starts it.
boxen create codex-project --agent codex
boxen run codex-project

# The same in Docker Cloud.
boxen create team-project --cloud --agent claude
~~~

The first `create` builds the tools image, which takes 15 to 30 minutes (Chrome
and nvChad take the longest); sbx caches it, so later sandboxes start in
moments, and changing a runtime script rebuilds only the last step.

Creation stays detached so preview servers continue after closing your terminals.
Stop with `stop`; reconnect with `shell` or `run`. Files persist across a stop
and resume. Commands that take a name check that the sandbox exists first, so a
mistyped name never creates a sandbox; only `create` does. A name is unique
across local and cloud sandboxes.

Each local sandbox gets 4 CPUs (or fewer on a smaller host) and 4 GiB unless you
pass `--cpus` and `--memory`, or set `BOXEN_CPUS` and `BOXEN_MEMORY`. Every
sandbox is a microVM that holds its memory. On Linux, `create` refuses to start
one when available memory is below its size plus 1 GiB; a concurrent test
microVM once exhausted the validation host. `BOXEN_SKIP_MEMORY_CHECK=1`
skips the check.

On first creation, SBX may ask for a network preset and approval of declared
credential destinations. Balanced is its default-deny development preset. The
kits add their own download/API hosts; `--open-network` passes
`--allow-network '**'` for a sandbox that should reach every host, and the
account's or host's denies still win. A destination binding does not provide a
credential. Configure credential sources separately.

## Commands

| Command | Short form | What it does |
|---|---|---|
| `create NAME [DIRECTORY]` | `init`, `-i` | Create a sandbox; see below |
| `NAME`, `shell [--with-sudo] NAME [COMMAND...]` | `-s` | Open zsh, or run a command |
| `run NAME [-- ARGS...]` | | Attach to the sandbox's agent |
| `exec NAME COMMAND [ARGS...]` | | Run a command |
| `net NAME [-b ADDR\|-H HOST] [-l] [-r PORT] [PORT\|HOST:SANDBOX\|supabase ...]` | `-n` | Locally, publish ports on the host through `sbx ports`; on a cloud sandbox, an SSH tunnel to `127.0.0.1` on this laptop. `-r all` is not supported |
| `env NAME VAR` | `-e` | Set a variable; prompts without echoing |
| `stop NAME`, `kill-all` | `kill`, `-k`, `-ka` | Stop one sandbox, or every running boxen sandbox |
| `delete NAME` | `-d` | Remove it, after sbx asks to confirm |
| `update NAME`, `update-all`, `cron install [HOUR]\|remove\|status` | `-u`, `-ua` | `apt-get upgrade` as root, on demand or nightly |
| `status [--once]`, `ls` | | `sbx tui`, or the sandbox list once; cloud sandboxes follow under `Cloud` |

`auth`, `tailscale`, `check`, `validate` and `doctor` are described below, and
`boxen --help` lists every option. Every command routes a cloud sandbox to
Docker Cloud by itself, and `kill-all` and `update-all` cover both.

`boxen status` opens sbx's dashboard, which `sbx tui` (or plain `sbx`) also
opens. It shows each sandbox's status, CPU and memory, with keys to start or
stop one (`s`), attach to its agent (Enter), open a shell (`x`) or remove it
(`r`). Tab switches to the network panel, which logs outbound connections and
lets you allow or block hosts. `?` lists every shortcut.

## Choosing kits

In a terminal, `create` opens a selector: choose one agent and any of five
options. Arrow keys or j/k move, Space chooses, Enter creates, and q quits
without creating anything. No option starts selected, and these flags pre-select
some: `--agent NAME`, `--claude`, `--codex`, `--grok`, `--tailscale`,
`--supabase-serve`, `--gh-token`, `--1pass`, `--rtkplus`.

`--plugins` chooses without the selector, as do `--no-tui` and non-interactive
runs:

~~~bash
boxen create web --tailscale --supabase-serve --gh-token --no-tui
boxen create small --plugins gh-auth,rtkplus --claude
boxen create everything --plugins all
boxen create base --plugins none
boxen create preview --dry-run
~~~

Every tool is in every sandbox, so tools are not a choice: see [Kits](#kits).
Supabase Serve automatically selects Tailscale. RTK's hooks apply to Claude and
Codex; with the shell or Grok, `rtkplus` is left out and `create` says so. Each
sandbox runs one agent; create a second sandbox for another agent.

## Workspace behavior

| Option | Behavior |
|---|---|
| Default | Copies the current directory (or `-p PATH`) once into `/workspace`, including uncommitted files and `.git`. No host bind mount. |
| `--no-copy` | Empty `/workspace`. Clone or create a repository inside it. |
| `--mode mount` | Explicit read/write host workspace mount. |
| `--mode clone` | SBX's private Git clone workflow; requires a host Git worktree. |

A copied or empty workspace is ordinary sandbox disk at `/home/agent/workspace`,
linked from `/workspace` and owned by the agent. It survives a stop and resume,
like everything else in the sandbox, including packages from `update`; deleting
the sandbox deletes it.

Copy mode has no automatic synchronization back to the host: commit and push,
or use `sbx cp`, to bring work out. The launcher refuses to copy your home directory or `/`.
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
SSH clients forward an SSH agent into sandboxes; boxen connects with
`sbx exec` instead. To rule it out entirely:
`sbx settings set ssh.agentForwardingEnabled false`.

The launcher forwards host Git name/email when configured. It does not copy Git
credentials, agent login files, SSH private keys, or your host home directory.

## Sudo

Docker's images give the agent user standing passwordless sudo. On a local
sandbox, boxen removes it when the sandbox is created. For root, open a session
with `./boxen shell --with-sudo NAME`: it adds a `_sudo` group to that session
only. Agents are told to ask you instead of using sudo.

Cloud sandboxes keep Docker's sudo: `sbx --cloud exec` cannot run as root, so
sudo is the only way to root there. `update`, `update-all` and the Tailscale
commands run through `sudo -n` on a cloud sandbox, and `shell --with-sudo` just
opens the shell.

## Kits

`v3/boxen` is the workload: one image, built `FROM` Docker's
`docker/sandbox-templates:shell-docker` template (Ubuntu 26.04), pinned by
digest. Docker's own Claude and Codex images are built on the same template,
which matters for apt: an agent mixin changes files only on top of a base it
expects, and a different base would leave its packages unknown to dpkg. sbx
builds the image on the first `create` and caches it. It has:

| Tools | Details |
|---|---|
| Docker | Native private Docker Engine and Compose |
| Shell and languages | mise, Node 22, Go, zsh with Oh My Zsh, the dpoggi theme and autosuggestions; GitHub CLI, database clients and common build dependencies. mise trusts config files anywhere under `/workspace` |
| Chromium/Playwright | Playwright 1.61.1 with Chromium, plus a **matched** Chrome for Testing/ChromeDriver pair (155.0.8059.39) for Wallaby |
| fzf, bat, just, Glow | mise-managed (fzf 0.74.5, bat 0.26.1, just 1.58.0, Glow 3.0.0), with the f and gdiff shell helpers |
| mermaid-ascii, Overmind | mermaid-ascii 1.4.0; Overmind 2.5.1 with tmux |
| nvChad | chadfennell/nvChad, Neovim v0.12.6, tree-sitter parsers and six Mason language servers |
| cubic | The vendor's user-level installer; log in on first use |
| RTK | 0.51.0; the `rtkplus` option adds its hook for Claude or Codex |
| Tailscale, 1Password | Tailscale 1.104.1 and op 2.30.0; their options turn them on |
| Skills | Every skill from [MixTapeSoftware/skills](https://github.com/MixTapeSoftware/skills), such as botfight, for Claude Code (in `/etc/claude-code/.claude/skills/`) and for Codex and Grok (in `~/.agents/skills/`) |

Agents are Docker's agent mixins, pinned by tag and digest in `lib/pins.sh`:
`docker/sbx-kit-claude-mixin`, `-codex-mixin` and `-grok-mixin`, at the newest
versions sbx v0.47.0 reads. The workload's entry script starts the agent
`BOXEN_AGENT` names, or a login shell. Boxen's options are mixins beside the
workload, each a single YAML file that runs scripts the image already has:

| Mixin | What it adds |
|---|---|
| `v3/workspace` | The agent-owned workspace and the `/workspace` link (copied and empty workspaces) |
| `v3/tailscale` | A userspace Tailscale node per sandbox; with Supabase Serve, the seven routes |
| `v3/gh-auth` | A proxy-managed GitHub token, and Git's credential helper through gh |
| `v3/1pass` | 1Password's hosts for the baked op CLI |
| `v3/rtkplus-claude`, `v3/rtkplus-codex` | RTK's hook for that agent |

Setup the agent needs on its first command runs as an install hook, once, at
create: removing local sudo, the environment line, the workspace, gh's
credential helper, the RTK hooks and the serve preset. Startup hooks are for
daemons and repair: Tailscale's daemon, and the environment line if sbx rewrote
the file. No Boxen kit declares a volume. Guest scripts live at
`/usr/local/share/boxen/`.

Downloads of pinned binaries (mise, Tailscale, the 1Password CLI, Chrome for
Testing, Neovim, mermaid-ascii) are checked against SHA-256 sums. The boundary is
stated, not implied: `node@22`, the Oh My Zsh and autosuggestions clones, the
skills, and the cubic, Grok and RTK vendor installers float, so a cold build is
repeatable for the checksummed artifacts, not byte for byte.

The workload's network rules are the union of what Boxen's tools need at
runtime (GitHub, Ubuntu, Node, Go, Mason, Chrome for Testing and cubic among
them). They include the CloudFront hosts that serve `public.ecr.aws` image
layers, such as Supabase's local stack: sbx's Balanced preset allows the
registry but not its CDN, so those pulls fail without them; `deno.land`, which
the Supabase CLI's edge runtime imports from when it starts; and Supabase's
hosted MCP server at `mcp.supabase.com`. Tailscale's, 1Password's and
`gist.github.com` stay with their mixins. When a tool fails to reach a host, the
network panel in `sbx tui` (or `sbx policy log`) shows what was blocked; allow
it there or with `sbx policy allow network HOST`. A blocked host can also
surface as a DNS error, since sandbox DNS answers only allowed hosts.

A sandbox made by hand looks like this:

~~~bash
sbx create --name try-v3 --cpus 4 --memory 4g --env BOXEN_AGENT=claude \
  --kit docker.io/docker/sbx-kit-claude-mixin:2.1.267 --kit ./v3/workspace ./v3/boxen
~~~

Add `--kit ./v3/<mixin>` for each option you want. With `v3/tailscale`,
`--env BOXEN_SERVE_PRESET=supabase` picks the Supabase routes. A cloud sandbox
made by hand also needs `--env BOXEN_CLOUD=1`: without it the install hook
removes the agent's sudo, and a cloud `exec` cannot run as root, so the sandbox
has no way back to root. Host kit paths are calculated from the launcher's
location, so the checkout can live anywhere.

## Cloud sandboxes

`boxen create NAME --cloud` makes the same sandbox in Docker Cloud: the same
image and kits, uploaded from this checkout, billed while it runs.

- **It stops; it is never deleted at expiry.** Each cloud sandbox is created
  with `--on-timeout stop` and a period from `BOXEN_CLOUD_TTL`: whole hours from
  1 to 24 (`8` or `8h`, the default), or minutes from 5 to 59 (`5m`). A stopped
  sandbox keeps its files and bills no compute; `boxen NAME` resumes it, with
  its id and a fresh period. After its setup, `create` reads the period back,
  extends one that came up short, and prints when it stops.
- **Docker caps a cloud sandbox at 24 hours from creation**, a clock that runs
  while it is stopped too. Whether a stopped sandbox can still be resumed after
  that is what `tests/host/day2-probe.sh` checks. Until it passes, treat a cloud
  sandbox as one copy of your work on someone else's service: work lives only
  in the sandbox until you push it, so commit and push often.
- **Workspaces are copied or empty.** `--mode mount`, `--mode clone` and
  `--skills` need this host and are refused. `--cpus` and `--memory` go to the
  cloud only when given; otherwise Docker's default applies (`BOXEN_CPUS` and
  `BOXEN_MEMORY` are local settings).
- **Credentials are set before the sandbox starts.** A GitHub token from the
  prompt or `--gh-token-stdin` is stored as a sandbox-scoped secret before the
  run, and only if none exists: `create` never replaces a credential it did not
  make. If creation fails before the sandbox exists, it removes only the secret
  it stored; if it fails after, it keeps the sandbox and its secret and says
  `boxen delete NAME`. Host-resolved secrets (`auth github --from-gh`,
  `auth 1password`) are refused. Whether a service secret set later with
  `boxen env` applies at once or at the next start is recorded by the cloud
  gate; until it reports, `boxen env` says the next start.
- **Root goes through Docker's sudo**, which cloud sandboxes keep: `update`,
  Tailscale and the Supabase routes work there (see [Sudo](#sudo)).

Previews never use Docker's public cloud ports. `boxen net NAME PORT` (or
`HOST_PORT:SANDBOX_PORT`, or `supabase` for the seven Supabase ports) opens one
background SSH connection to the sandbox and forwards each port to
`127.0.0.1` on your laptop, so the app and Supabase have the same `localhost`
addresses as in local development, and only you reach them. The tunnel lasts
while the laptop is awake: `boxen net NAME -l` lists the forwards and marks a
tunnel that closed, `boxen net NAME` reopens it with the same forwards, `-r PORT`
removes one, and `stop`, `delete` and `kill-all` close it. `-b` and `-H` are
refused: share from your laptop with `tailscale serve`, or give the sandbox
`--tailscale` for a stable private address on your tailnet.

Docker Engine and Compose are in every sandbox. Whether Supabase's local stack
(Compose with healthchecks) runs inside a cloud sandbox is checked by
`tests/host/cloud-gate.sh`; until it passes, run it in a local sandbox.

## Host setup and Chadmux

`./install` links `boxen` into `~/.local/bin`; the launcher follows the link
back to this checkout's `v3/` kits. It then offers Chadmux, Chad's opinionated tmux
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
entering a sandbox that is not signed in (`boxen NAME`, `boxen shell NAME`,
`boxen run NAME`). Claude Code uses `claude auth login`; Codex uses
`codex login --device-auth`, a code you enter in your browser, since its usual
`localhost` callback cannot reach a sandbox. Answer n to skip; the offer comes
back next time.

The login lives inside the sandbox, where the agent can read it. It survives
a stop and resume and goes away with the sandbox.

Do not store `anthropic` or `openai` secrets host-wide with `sbx secret set`:
Docker's Claude and Codex mixins then use that one credential in every
sandbox instead of the sandbox's own sign-in. `create` and `doctor` warn when
one exists; remove it with `sbx secret rm anthropic` (or `openai`). Grok uses
an xAI API key; `boxen env NAME XAI_API_KEY` stores one for that sandbox only.

### Plugin keys

In a terminal, `create` asks for the keys its plugins need before it starts
provisioning. Leave any blank to skip it.

| Plugin | Asks for | Where it goes |
|---|---|---|
| gh-auth | A fine-grained GitHub token (Contents read/write, Metadata read-only) | An sbx secret scoped to this sandbox; the `gh-auth` mixin declares it as a proxy-managed `GH_TOKEN`, so the proxy injects it and the sandbox sees a placeholder |
| 1pass | A 1Password service account token | Inside the sandbox, for `op`; the agent can read it |
| tailscale | A tagged auth key, and a dev port for :443 unless Supabase Serve is selected | Straight to the sandbox's tailnet join; not stored |

Without a terminal, or after skipping, add them later:

~~~bash
boxen auth github my-project                    # paste a fine-grained token, or pipe one in
op read 'op://Work/GitHub/fine-grained-token' | boxen auth github my-project
boxen auth github my-project --from-gh          # the host gh token, with every scope gh has
boxen env my-project OP_SERVICE_ACCOUNT_TOKEN
boxen tailscale join my-project
boxen auth 1password my-project github 'op://Work/GitHub/token'  # host op:// reference
~~~

Sandbox-scoped sbx secrets are removed with the sandbox. `--gh-token-stdin`
reads the token from stdin's first line instead of a prompt, for scripts. On a
cloud sandbox, `--from-gh` and `auth 1password` are refused: cloud secrets
cannot run host commands, so pipe the token in instead.

Sandboxes created before v3 keep their scripts in an older place;
`boxen NAME`, `shell`, `check` and the sign-in offer still work on them, and
nothing recreates them. They get none of the v3 kits: recreate one to move it
to v3.

### Other tokens and variables

`boxen env NAME VAR` sets `VAR` in a sandbox. `VAR` is the variable's name; the
value comes from a hidden prompt or stdin, never an argument:

~~~bash
boxen env my-project SOME_TOKEN                  # prompts for the value
op read 'op://Work/Some/token' | boxen env my-project SOME_TOKEN
~~~

Where the value goes depends on the name:

| Name | Stored as | The sandbox sees |
|---|---|---|
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `XAI_API_KEY`, `GH_TOKEN`, `GITHUB_TOKEN`, `GROQ_API_KEY`, `MISTRAL_API_KEY`, `OPENROUTER_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_API_KEY` | A sandbox-scoped sbx secret for that service | A placeholder; the proxy injects the real value |
| Anything else | A line in `~/.config/boxen/env.sh` inside the sandbox, loaded by every shell | The real value, which the agent can read |

For a token that only travels to an API, keep it out of the sandbox with an
[sbx custom secret](https://docs.docker.com/ai/sandboxes/configuration/credentials/#custom-secrets)
instead. Run on the host:

~~~bash
sbx secret set-custom --sandbox my-project \
  --host api.example.com \
  --env EXAMPLE_API_KEY \
  --ref 'op://Work/Example/api-key'     # or --command 'example-cli token'
~~~

The command prints a placeholder (`sbx-cs-…`). When a request to a listed host
contains it, in a header or the body, the proxy swaps in the real value. A
sandbox that already exists does not get the variable, so store the
placeholder, which is not secret, with `boxen env`:

~~~bash
printf '%s' 'sbx-cs-…' | boxen env my-project EXAMPLE_API_KEY
~~~

Repeat `--host` for more domains; `*.example.com` matches one label. Avoid
`--value`, which leaves the token in shell history. sbx marks custom secrets as
experimental. Use `boxen env` alone when the program needs the token itself,
such as to sign requests or build a connection string.

Only requests through the sbx proxy get the real value. Code run directly in
the sandbox uses it already. Containers the sandbox's Docker runs, such as
Supabase's edge functions, reach the internet without it and send the bare
placeholder; give them `HTTPS_PROXY` and the proxy's CA certificate
(`$PROXY_CA_CERT_B64`, base64) to get the swap.

`sbx secret ls` on the host lists secrets with masked values. To see which
variables a sandbox's `env.sh` sets, without the values:

~~~bash
sbx exec my-project sh -c 'sed -n "s/^export \([^=]*\)=.*/\1/p" ~/.config/boxen/env.sh'
~~~

## Tailscale and previews

Join through the browser/device flow:

~~~bash
./boxen tailscale join my-project
./boxen tailscale status my-project
~~~

Or pipe a tagged auth key directly from a secret manager:

~~~bash
op read 'op://Development/Tailscale/auth-key' |
  ./boxen tailscale join my-project --auth-key-stdin
~~~

The key travels on stdin into a temporary guest file with private permissions.
Tailscale receives that file's path; the file is removed afterward. No auth
key belongs in a kit, CLI argument, image, shell profile, or environment file.

**A joined sandbox reaches whatever your tailnet ACLs allow, outside sbx's
network policy.** Use a tagged key whose ACLs grant only what the sandbox
needs, and no exit nodes or Funnel. The node has no operator, so the agent
cannot change its settings; `join`, `serve` and `status` run as root.

~~~bash
./boxen tailscale serve my-project 5173
./boxen tailscale serve my-project supabase
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
once; tailscaled keeps serve config in its state, so it survives a stop and
resume. The preset owns :443, so a single-port `serve` is refused while it is
selected; run the app on port 3000. The preset configures routes, but does not
install or start Supabase. Enable Tailscale HTTPS when requested by Tailscale's
own flow.

Each environment has a separate node identity named after its sandbox. Its
state lives in `/var/lib/tailscale` on the sandbox's own disk: it survives a
stop and resume and goes away with the sandbox. Do not export an enrolled
environment as an image; it would carry the identity, and this wrapper
deliberately has no template-export command.

Tailscale works on cloud sandboxes too: `join`, `serve` and `status` run there
through Docker's sudo. For a preview on your own laptop alone, `boxen net` is
simpler; see [Cloud sandboxes](#cloud-sandboxes).

Userspace networking avoids a tunnel device and uses a local SOCKS5 listener for
outgoing tailnet connections. For an individual command:

~~~bash
curl --proxy socks5h://127.0.0.1:1055 http://other-machine:3000
~~~

Keep Docker's HTTP_PROXY/HTTPS_PROXY values intact so credential injection
continues working. Userspace mode does not provide transparent kernel routing.
Direct peer UDP is not enabled; relay performance depends on the
host network and SBX policy.

~~~bash
./boxen exec my-project tail /var/log/boxen/tailscaled.log
~~~

## RTK and editor details

`rtkplus` adds the agent's own RTK mixin at create. For Claude,
`v3/rtkplus-claude` adds RTK's PreToolUse command to `~/.claude/settings.json`
after Docker's Claude mixin has seeded it, keeping every other hook and setting.
For Codex, `v3/rtkplus-codex` runs `rtk init --global --codex`, which writes
hooks.json and instructions and leaves Docker's managed config.toml alone. Grok
can use the RTK CLI explicitly; this project does not claim an automatic Grok
hook.

NvChad is pinned to your configuration revision
c0e1543a7a64c8db877df02fc7decfb0a9e07ecb, with Neovim v0.12.6. Parser
installation failures fail the image build; `check` confirms the six Mason
language servers.

## Verify and develop

~~~bash
./boxen validate                # Docker's kit validator on v3/; requires login
./boxen check my-project        # Tool/browser/config checks inside the guest

python3 -m pip install -r tests/requirements.txt
bash tests/run.sh                    # Syntax and isolated host CLI tests

# v3 sandbox and workspace-copy checks; run sequentially with other VMs stopped.
bash tests/workload-smoke.sh claude rtk    # shell, claude, codex or grok; rtk or nortk
bash tests/host/smoke-gate.sh              # every agent, with and without RTK, and Tailscale
bash tests/host/update-gate.sh             # boxen update keeps every package
~~~

The host gates in `tests/host/` create real sandboxes on a machine with sbx and
Docker, on a shared library in which every check counts toward one exit status:

~~~bash
bash tests/host/compose-gate.sh      # the workload alone and with each agent mixin
bash tests/host/tools-gate.sh        # every tool baked in, build and rebuild times
bash tests/host/mixins-gate.sh       # every Boxen mixin on at once, for each agent, and a restart
bash tests/host/launcher-gate.sh     # boxen itself: create, check, validate, --open-network
BOXEN_CLOUD_POLICY_NOTE='your account network default' \
  bash tests/host/cloud-compose-gate.sh   # Docker Cloud: stop, SSH forward, a real expiry
bash tests/host/cloud-gate.sh        # boxen create --cloud end to end (see its header for inputs)
bash tests/host/expiry-gate.sh       # a real expiry of the launcher's cloud sandboxes
bash tests/host/acceptance-gate.sh   # all of them, once, on a clean revision
~~~

Set TEST_BASH to a Bash 3.2 executable to exercise the host CLI with it.
Tests never use personal credentials. Runtime checks do not authenticate
agents, join a tailnet, or read a vault automatically.

[AGENTS.md](AGENTS.md) has the rules for agents working on this repository.
Its skills, such as
[botfight](https://github.com/MixTapeSoftware/skills/tree/main/botfight), live
in `.agents/skills/`, linked for Claude Code and Grok. Refresh them from
MixTapeSoftware/skills with `bash scripts/sync-skills.sh`.

The code suite includes isolated Tailscale tests using fake commands for route
arguments, timeouts, and auth-file cleanup. Further live Tailscale smoke
validation is skipped for this prototype at the user's request.

Each workload check creates a disposable sandbox through `boxen create`,
capped at 2 GiB and two CPUs. It refuses concurrent sandboxes and, on Linux,
requires at least 4 GiB available memory before starting. It also checks that
RTK is composed as chosen, that the agent has no standing sudo, that
`--with-sudo` works, and that the copied workspace, with work done after the
copy, survives a stop and resume. Successful test sandboxes are removed;
failed ones are stopped if SBX retained them. The disk check requires 3 GiB
free once sbx has built the kit image (`sbx-kit-src`) or 12 GiB before. Logs
stay under ignored local/; a lock left by a dead run is reclaimed.
