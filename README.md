# Boxen

Development boxes for coding agents on **Fly.io Sprites**. One command
creates a Sprite for a project, locks down its network, installs the tools
you pick, clones the repository and drops you into a shell or your coding
agent. Fly owns the machine; nobody on the team runs or administers a Linux
host.

A Sprite is a Firecracker microVM running Ubuntu, with 8 vCPUs and a 100 GB
disk, as the user `sprite`. It sleeps about 30 seconds after the last session
closes and wakes on the next command. Files persist across sleep; running
processes do not. Compute is not billed while it sleeps; storage is.

The launcher is Bash 3.2 with standard Unix tools and jq. Python is needed
only for the development tests.

## For teammates

You need a Fly.io account in the team's organization, the
[sprite CLI](https://docs.fly.io/sprites/cli/installation), jq, and a GitHub
token for private repositories.

~~~bash
sprite login                  # opens a browser for your Fly account
git clone https://github.com/MixTapeSoftware/boxen.git && boxen/install
bxn doctor

cd ~/code/my-app              # a clone, so bxn knows the repository
bxn create my-app             # pick an agent and tools, paste a GitHub token
~~~

`create` names the Sprite after your handle, which it asks for once (for
example `ada-my-app`). It ends in a shell, or in your agent if you chose one.
Claude Code asks you to sign in with `/login` the first time: use your own
subscription. Codex offers a device sign-in.

Later, `bxn my-app` opens a shell, `bxn run my-app` starts the agent, and
`bxn list` shows your Sprites. To see a dev server, run
`bxn proxy my-app 3000` and open `http://localhost:3000`.

**Anyone in the Fly organization can open any Sprite and read what is in it**,
including your Claude login and tokens. Treat a Sprite like a shared server.

## Commands

| Command | What it does |
|---|---|
| `create PROJECT [REPO]` | Create, lock down, provision, clone, open; see below. Also `init`, `-i` |
| `PROJECT`, `shell PROJECT [COMMAND...]` | zsh in `/workspace`, or run a command. Also `-s` |
| `run PROJECT [-- ARGS...]` | Start the agent in `/workspace` |
| `exec PROJECT COMMAND [ARGS...]` | Run a command as the Sprite's user |
| `clone PROJECT [REPO]` | Clone into an empty `/workspace`, with the Sprite's GitHub token; for a Sprite made with `--no-clone`, or after a failed clone |
| `list [--all]` | Your Sprites and whether each is cold, warm or running; `--all` shows the org's. Also `ls` |
| `delete PROJECT [--yes]` | Destroy it, checkpoints included. Also `destroy`, `-d` |
| `allow PROJECT HOST...` | Allow more hosts; see [Network](#network-and-privileges) |
| `policy PROJECT` | Show the network policy and privileges profile |
| `env PROJECT VAR` | Set a variable; the value comes from a hidden prompt or stdin. Also `-e` |
| `auth github PROJECT` | Store a GitHub token, from a prompt or stdin |
| `checkpoint PROJECT [COMMENT]`, `checkpoints PROJECT` | Snapshot the whole filesystem; list snapshots |
| `restore PROJECT ID [--yes]` | Roll back to a snapshot, discarding everything since |
| `proxy PROJECT PORT\|LOCAL:REMOTE...\|supabase` | Forward ports to `localhost` on this machine |
| `url PROJECT` | The Sprite's private URL |
| `check PROJECT` | Check the base tools and every chosen plugin |
| `plugins`, `handle [NEW]`, `doctor` | List plugins; show or change your handle; check prerequisites |

`PROJECT` is a Sprite's name without your handle; the full name works too.
Commands that take one check that the Sprite exists first, so a typo never
creates anything; only `create` does. Set `BOXEN_SPRITE_ORG` when you belong
to more than one Fly organization.

## Creating a Sprite

~~~bash
bxn create web                        # the current clone's origin
bxn create web acme/web               # or owner/repo, or an https URL
bxn create scratch --no-clone         # an empty /workspace
bxn create web --claude --docker      # flags preselect in the picker
bxn create web --plugins gh-auth,just --no-tui --gh-token-stdin < token.txt
bxn create web --dry-run              # the plan, without creating anything
~~~

`create` runs these steps, and stops at the first that fails, except as step
6 says:

1. Checks that the `sprite` CLI is logged in and the name is free.
2. Runs `sprite create --skip-console --label boxen HANDLE-PROJECT`.
3. **Locks it down** before anything runs in it: posts the network policy and
   the privileges profile, then reads the policy back from inside the Sprite
   and the profile from the API. A Sprite that does not enforce what was set
   is destroyed.
4. Installs the base: build tools and libraries, database clients, zsh with
   Oh My Zsh, tmux, ripgrep, mise with Node 22 and Go, and the GitHub CLI.
5. Checks the agent (Sprites ship Claude Code and Codex; Grok is installed),
   then installs each plugin in order.
6. Copies your Git name and email, stores the keys you pasted, and clones the
   repository into `/workspace`. A key that fails to store or a clone that
   fails only warns, with the command to retry, and `create` goes on. Retry
   a clone with `bxn clone PROJECT`, after `bxn auth github PROJECT` for a
   private repository.
7. Opens a shell, or the agent; `--detach` skips this.

In a terminal, a picker chooses one agent and the plugins; arrow keys or j/k
move, Space chooses, Enter creates and q quits. If a later step fails, `create`
offers to destroy the half-made Sprite. When the organization is at its limit
of awake Sprites, `create` says so.

No project files are copied from your machine. Boxen sends its own scripts,
your Git name and email, and the keys you paste; the repository is cloned
inside the Sprite, so a private one needs the GitHub token. SSH remotes on
GitHub become https URLs.

## Plugins

`bxn plugins` lists them. The ones marked default are preselected.

| Plugin | Default | What it adds |
|---|---|---|
| gh-auth | yes | A fine-grained GitHub token for gh and Git, asked for at create |
| gh-stack | yes | GitHub's [gh stack](https://github.com/github/gh-stack) v0.2.1 and its agent skill |
| skills | yes | Every skill from [MixTapeSoftware/skills](https://github.com/MixTapeSoftware/skills), such as botfight, for Claude Code, Codex and Grok |
| fzf-bat, just, glow | yes | fzf 0.74.5 and bat 0.26.1 with the `f` and `gdiff` helpers, just 1.58.0, Glow 3.0.0 |
| mermaid-ascii, overmind | | mermaid-ascii 1.4.0; Overmind 2.5.1 |
| rtkplus | | RTK 0.51.0 and its hook for Claude or Codex |
| 1pass | | 1Password CLI 2.30.0; asks for a service account token |
| cubic | | cubic, through the vendor's installer |
| chromium | | Playwright 1.61.1 with Chromium, and a matched Chrome for Testing and ChromeDriver (155.0.8059.39) |
| nvchad | | chadfennell/nvChad on Neovim v0.12.6, with tree-sitter parsers and six Mason language servers. The slowest |
| docker | | Docker Engine, Compose and Buildx, with dockerd as a Sprite service. Experimental |
| supabase-serve | | Supabase's hosts and `bxn proxy PROJECT supabase`; adds docker |

A plugin is a small file in `plugins/` that names the hosts it needs and the
privileges profile it asks for, and runs scripts from `guest/` in the Sprite.
Pinned downloads (mise, gh, gh stack, mermaid-ascii, 1Password, Neovim,
Chrome for Testing) are checked against SHA-256 sums. The Oh My Zsh clones,
the skills repository, `node@22`, and the cubic, RTK, Grok and Claude
installers float.

## Network and privileges

A Sprite starts able to reach any host. Boxen sets its policy from outside
before anything runs in it, and the agent inside cannot change it: the
Sprite holds only a read-only copy at `/.sprite/policy/network.json`.

The policy is `policies/sprite-baseline.json`, which includes Fly's
`defaults` (GitHub, npm, PyPI, Docker Hub and the major AI APIs) and the
hosts base provisioning needs, plus the hosts the agent and each chosen
plugin declare. Those stay allowed, so the tools keep working. A blocked host
fails fast with a DNS refusal. Connections to raw IP addresses and private
ranges are refused.

~~~bash
bxn create web --allow api.example.com --allow '*.example.org'
bxn allow web registry.example.com    # later: reads, merges and posts the whole policy
bxn policy web
bxn create lab --allow-all            # no policy at all; it warns
~~~

The privileges profile is `standard`, or `privileged` when a chosen plugin
needs it (only docker does). The Sprite's user has sudo inside the Sprite;
the boundary is the VM and the policies set from outside.

## Credentials

Each teammate's Sprites hold their own credentials. Nothing comes from your
machine except what you paste or pipe.

| What | How | Where it goes |
|---|---|---|
| Claude Code | `/login` inside the Sprite, with your own subscription | Claude's own login in the Sprite |
| Codex | Device sign-in, offered by `create` and on the way in | Codex's own login in the Sprite |
| GitHub | Pasted at `create`, or `bxn auth github PROJECT` | `GH_TOKEN`; Git asks gh for credentials |
| 1Password | Pasted at `create`, or `bxn env PROJECT OP_SERVICE_ACCOUNT_TOKEN` | `OP_SERVICE_ACCOUNT_TOKEN` |
| Grok | Pasted at `create`, or `bxn env PROJECT XAI_API_KEY` | `XAI_API_KEY` |

Variables live in `~/.config/boxen/env.sh` in the Sprite, private to its
user, which every shell and the agent load. Values travel on stdin, never as
an argument:

~~~bash
bxn env web SOME_TOKEN                          # prompts without echoing
op read 'op://Work/Some/token' | bxn env web SOME_TOKEN
~~~

Use a fine-grained GitHub token limited to the repositories the Sprite
needs, with Contents read/write, Metadata read-only and an expiry. Fly's
Connectors could keep GitHub tokens out of Sprites entirely; Boxen does not
use them yet.

## Previews

`sprite exec` forwards a port that a command opens to the same port on your
machine, so a dev server started in `bxn shell` is often reachable at once.
Otherwise:

~~~bash
bxn proxy web 5173                    # localhost:5173
bxn proxy web 3001:3000               # localhost:3001 to the Sprite's 3000
bxn proxy web supabase                # 3000, 54321, 54323, 54324 and 8000
~~~

Every Sprite also has an HTTPS URL that reaches its port 8080 and needs a
Fly login from your organization (`bxn url web`). Boxen never makes it
public.

## Sleep, checkpoints and cost

A Sprite sleeps by itself, so there is no `stop`. An open shell or agent
session keeps it awake. A dev server started by hand stops when it sleeps.

`bxn checkpoint web` snapshots the whole filesystem; `bxn restore web ID`
rolls back to one and discards everything since, so checkpoint first.

Fly bills per second while a Sprite is awake: $0.07 per CPU-hour and
$0.04375 per GB-hour of memory, plus storage. Fly's example is $0.44 for a
four-hour Claude session. The organization can have 3 Sprites awake at once
on pay-as-you-go, or 10 on the $20 plan; `bxn list --all` shows who holds
them.

## Host setup and Chadmux

`./install` links `bxn` into `~/.local/bin`, and the launcher follows the
link back to this checkout. It then offers Chadmux, Chad's opinionated tmux
config, with TPM plugins for the Dracula theme, tmux-yank and
vim-tmux-navigator. `./install --chadmux` installs it without asking, and
`--no-chadmux` skips the question. Chadmux never moves, replaces or links
over an existing tmux config. It is a host setup; Sprites do not get it.

## Develop

~~~bash
bash tests/run.sh            # syntax of every script, and the Python tests
bash tests/sprite/spike.sh   # creates a real Sprite; see below
~~~

The tests run the launcher against a fake `sprite` CLI
(`tests/fakes/sprite`) and the guest scripts against fake tools, so they need
no Fly account. Set `TEST_BASH` to a Bash 3.2 executable to run them with it.

[AGENTS.md](AGENTS.md) has the rules for agents working on this repository,
and the design is in
[docs/superpowers/specs/2026-10-29-sprites-design.md](docs/superpowers/specs/2026-10-29-sprites-design.md).

### Not verified on a real Sprite yet

Boxen moved from Docker Sandboxes to Sprites on 2026-10-29, and no Sprite
has been created with it yet. `tests/sprite/spike.sh` checks what the design
could not take from Fly's documentation; run it on a machine logged in to
the team's organization, and record the results in the design's Review log:

- the path form `sprite api` takes for a Sprite's own policies, which
  lock-down depends on;
- that stdin, including payloads over 64 KB, reaches commands through
  `sprite exec`;
- that Docker runs at all, and under which profile;
- whether a non-admin member can reach another member's Sprite URL;
- whether Git works through a GitHub Connector, which would let Boxen drop
  GitHub tokens;
- whether a checkpoint can seed a new Sprite;
- that a login zsh reads `.zshenv`.
