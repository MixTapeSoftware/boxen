# Sprites backend: design

2026-10-29. Draft for Chad's read. Decisions marked *(Chad)* came from the
conversation; the rest are the author's calls and can be overturned.

## How this applies to Boxen

The design below was written for incs, where Sprites sit beside Incus. On
2026-10-29 Chad chose to abandon Docker Sandboxes in Boxen and rebuild it on
Sprites as a full do-over. Boxen therefore has one backend, and these
readings of the design hold *(builder's calls, open to Chad's review)*:

- **One front door.** `bxn` stays the command; there is no `sprs` and no
  `incs` beside it. Everything Incus- or sbx-specific goes: `v3/` kits, sbx
  bindings, the Claude proxy token, sudo removal, Tailscale, cron and bulk
  commands.
- **The plugin contract is kept** with only its Sprites implementation:
  `box_root`, `box_user` and `box_set_env` live in `lib/box.sh`, plugins
  never call `sprite` themselves, and the tests fake one binary.
  `PLUGIN_BACKENDS` is left out, since there is one backend.
  `PLUGIN_PRIVILEGES` and `PLUGIN_EGRESS_HOSTS` are implemented.
- **Tools become plugins.** Sprites have no images, so the tools sbx baked
  into one image (fzf and bat, just, Glow, mermaid-ascii, Overmind, cubic,
  Chromium, nvChad, gh stack, skills, 1Password, RTK, Docker) are installed
  at create by the plugin picker. The quick ones are selected by default.
- **Egress, the open question:** option 1, the author's recommendation. Each
  plugin declares `PLUGIN_EGRESS_HOSTS`; create merges them with the shipped
  baseline and `--allow` extras, and they stay allowed. Chad can overturn
  this.
- **Tailscale is gone**, as the inventory says for Sprites. Supabase Serve is
  a `sprite proxy` preset and adds the Docker plugin.
- **Docker is experimental** until spike item 4 runs: the plugin asks for
  the `privileged` profile and starts dockerd as a `sprite-env` service.
- **Claude** signs in with `/login` inside each Sprite. Codex keeps its
  device sign-in offer. Grok reads `XAI_API_KEY` from `bxn env`.
- **Sudo stays.** The Sprite's user has sudo; the boundary is the VM and the
  policies set from outside, which the agent cannot change.
- **URL access:** the Sprites API accepts only `url_settings.auth`, not
  `private_access`, so Boxen leaves the URL at its private default and never
  makes it public. Spike item 5 reports what a non-admin member sees.
- **`sprite api` path form** is not documented. Boxen uses
  `sprite api -s NAME /policy/...` in one function; spike item 9 says
  whether that is right. Lock-down reads the policy back inside the Sprite,
  so a wrong form fails create and destroys the Sprite rather than leaving
  it open. An interrupt before lock-down is verified also destroys it,
  without asking; the destroy offer below applies only after that point.
  Only a kill or crash in that window, before anything is installed, can
  still leave an empty Sprite unrestricted.
- **Phase 2 (Connectors) is not built**; it waits on spike item 6.
- The handle lives in `~/.config/boxen/handle`; Sprites carry the label
  `boxen`.

## What and why

Teammates get the incs experience on a Fly.io Sprite instead of a local Incus
container: one command creates a sandboxed Linux box, installs the plugins
they pick, clones the repo, and drops them into a shell with their coding
agent. Nobody on the team runs or administers a Linux host. *(Chad)*

Chad keeps using incs locally. Sprites are the path for teammates who won't run
Linux or Colima, and Chad won't manage a box for them. *(Chad)* This fits the
2026-10-27 decision that incs stays local-only: the reason remote Incus was
shelved was owning a server, and a Sprite is a box Fly owns.

The whole team is in one Fly organization. *(Chad)*

## What Sprites give us for free

Verified against the Sprites docs on 2026-10-29. Each point retires work incs
does itself.

- **A sandbox per project.** Each Sprite is a Firecracker microVM running
  Ubuntu 25.10, 8 vCPU, 100 GB disk, as user `sprite` with sudo. Created in
  one to two seconds.
- **Egress allowlist.** A per-Sprite policy of allow and deny domain rules,
  with an `include: defaults` preset (GitHub, npm, PyPI, Docker Hub, major AI
  APIs). Raw-IP connections that bypass DNS are refused unless the IP resolved
  from an allowed domain. Private ranges are always blocked. The Sprite can't
  edit its own policy; it's read-only at `/.sprite/policy/network.json` and
  set from outside through the API. Tightening drops existing connections.
  This replaces the bridge, ufw and egress-container stack on this backend.
- **Privileges policy.** A capability profile (`minimal`, `standard`,
  `privileged`), a device allowlist and `noNewPrivileges`, also set from
  outside.
- **Credential gateway ("Connectors").** GitHub OAuth or any token-based API
  can be stored in the org and reached from a Sprite through
  `https://api.sprites.dev/v1/gateway/<provider>/<id>/…`. The Sprite never
  holds the token. Access is granted by Sprite name prefix or labels,
  deny-by-default. This is the token injection incs shelved on 2026-10-27.
- **Reachability without Tailscale.** Every Sprite has an HTTPS URL, private
  to the org by default, routed to port 8080. `sprite proxy <port>` forwards
  any other port to the laptop.
- **Checkpoints.** Whole-filesystem snapshot and restore in about a second.
- **Preinstalled agents.** Claude Code, Codex, Gemini CLI and Cursor are in the
  base image, along with Node, Python, Go, Ruby, Rust, Elixir, Bun, Deno,
  git, curl and vim.
- **Sleep.** A Sprite pauses about 30 s after activity stops and wakes on the
  next command in well under a second. An open TTY session counts as
  activity, so an agent session stays up. Processes die on sleep; files
  persist. Compute is not billed while asleep; storage is.

Costs, from Fly's pricing page: $0.07 per CPU-hour and $0.04375 per GB-hour of
RAM, billed per second of wall time while awake, plus $0.50/GB-month hot and
$0.02/GB-month cold storage. Fly's example is $0.44 for a four-hour Claude
session. Pay-as-you-go allows 3 running Sprites per org; the $20/month plan
allows 10 and includes 450 CPU-hours.

## Must

- One command takes a teammate from "logged into the `sprite` CLI" to "shell
  open in a provisioned Sprite with the repo cloned". Same plugin picker and
  flags as incs where they apply.
- Network and privileges policy are applied right after `sprite create`,
  before any provisioning, token or clone touches the Sprite. A Sprite is
  born unrestricted, and this tool must never leave one that way.
- Every plugin runs unchanged on both backends, or declares that it doesn't
  support one.
- No change to the incs experience on Incus. The Incus lifecycle code gets no
  Sprites conditionals.
- Secrets never appear on a command line, in `--env` flags, or in logs. The
  stdin and `%q` patterns the plugins already use carry over.
- Teammates need no knowledge of Incus, Colima or this tool's internals. The
  README section for them fits on one screen.

## Must not

- Require Chad to do anything per teammate beyond adding them to the Fly org.
- Reimplement what Sprites provide: no proxy, no firewall, no VPN, no image
  templates on this backend.
- Add a new programming language or build step. Bash 3.2, like the rest of
  the repo.
- Run anything on Chad's machines on a teammate's behalf.

## Shape

### One repo, two front doors

The Sprites tool lives in this repo as a sibling of incs, not as a flag on it
and not as a separate repo (yet). `incus.init` is 1,200 lines, most of it
Incus lifecycle that doesn't apply; `sprite.init` is a new, much shorter file.
Splitting the repo later is cheap once the plugin contract below is stable,
and not possible before.

What both inits share is extracted, not copied: plugin discovery and sorting,
the TUI picker, flag aliasing, the plugin runner (`_run_plugin_*`), the apt
package list, oh-my-zsh and the dotfile steps move out of `incus.init` into a
backend-neutral file (author's name: `box.provision`) that both inits source,
along with `incus.prompt`. That extraction is PR 1 and changes no behaviour on
Incus. "No Sprites conditionals in the Incus lifecycle code" still holds: the
shared file knows about backends only through the `box_*` functions below.

Author's call on names: the command is `sprs`, installed by `install_shortcuts`
next to `incs`. The scripts follow the existing pattern (`sprite.init`,
`sprite.shell`), so the pair reads `incus.init` / `sprite.init`.

### The plugin contract

Today every plugin talks to the box through two verbs: `incus exec` (as root,
or as the user via `su - $HOST_USER -c 'bash -s' <<EOF`) and
`incus config set environment.X`. Replace the direct calls with three
functions the backend defines before sourcing a plugin:

| Function | Meaning | Incus | Sprites |
|---|---|---|---|
| `box_root cmd…` | run as root, stdin passed through | `incus exec $C -- cmd…` | `sprite exec -s $C -- sudo cmd…` |
| `box_user cmd…` | run as the instance user, stdin passed through | `incus exec $C -- su - $HOST_USER -s /bin/sh -c 'exec "$0" "$@"' cmd…` | `sprite exec -s $C -- cmd…` |
| `box_set_env NAME VALUE` | persistent env var for the user | `incus config set … environment.NAME` plus `.zshenv` | `.zshenv` only |

The backend also exports `BOX_BACKEND` (`incus` or `sprite`), `BOX_USER`
(`$HOST_USER` or `sprite`) and `BOX_HOME`. Plugins stop referring to
`$CONTAINER_NAME`, `$HOST_USER` and `incus` directly.

AGENTS.md's rule "install agent tools as the instance user without relying on
sudo" stays true for plugin authors: they call `box_root` for system packages
and `box_user` for everything else, and only the Sprites backend turns
`box_root` into `sudo`.

A plugin that can't work on a backend sets `PLUGIN_BACKENDS="incus"` (default
`"incus sprite"`). The TUI hides it; the CLI flag errors with a one-line
reason. A plugin that works on both but has a backend-only step (docker's
`security.nesting` config and restart on Incus) wraps that step in
`if [[ "$BOX_BACKEND" == incus ]]`; whole-plugin exclusion is
`PLUGIN_BACKENDS`, step-level is the branch. Direct `incus` calls are allowed
only inside such a branch.

Two more optional metadata fields, both ignored by the Incus backend:

- `PLUGIN_PRIVILEGES` (`standard`, the default, or `privileged`): the
  privileges profile the plugin needs. The Sprite gets the highest profile
  any selected plugin asks for.
- `PLUGIN_EGRESS_HOSTS`: space-separated domains the plugin's install and
  runtime need (see Egress baseline). *Pending Chad's answer on provisioning
  egress.*

Each `sprite exec` is a separate session, so nothing carries between calls.
The plugins already assume that. `sprite exec` is known to drop early output
over 64 KB (sprites-go issue #51); the builder decides whether to work around
it or accept lost install chatter.

### Plugin inventory

| Plugin | On Sprites |
|---|---|
| claude-code, codex | `plugin_is_installed` returns true (preinstalled); install path kept for an image that lacks them |
| fzf-bat, glow, just, mermaid-ascii, nvchad, chadmux, rtkplus, overmind, matt-pocock-skills, cubic, grok, chromium, 1pass | port through the contract |
| gh-auth | port; see Code and credentials |
| supabase-serve | port the serve preset to Sprite URL + `sprite proxy`; depends on docker |
| docker | `PLUGIN_BACKENDS` decided by the spike (below) |
| tailscale | `PLUGIN_BACKENDS="incus"`; the Sprite URL and `sprite proxy` cover what it was for |

### Boot sequence (`sprs -i <project>`)

1. **Preflight.** `sprite` CLI present and logged in (`sprite login` opens a
   browser against the teammate's Fly account); org resolved; name free.
2. **Create.** `sprite create <handle>-<project> --skip-console --label
   managed-by=agent-incus`. Fly identities are email addresses with no short
   username, so the handle is chosen on first run (default: the local
   `$USER`), validated against the Sprite name charset, and stored in
   `~/.config/sprs/handle`. It's what Connector name-prefix policies key on,
   and it tells the team whose Sprite it is.
3. **Lock down.** `POST /v1/sprites/<name>/policy/network` with the baseline
   below plus any `--allow` extras; `POST …/policy/privileges` with
   `standard`, or `privileged` if a selected plugin declares it. Both via
   `sprite api`. Verify by reading the policy back before continuing.
4. **Wait** until `sprite exec -- true` succeeds.
5. **Base provisioning.** The apt package list from `incus.init`, oh-my-zsh,
   and the dotfile steps, through `box_root` and `box_user`.
6. **Plugins**, in the existing order, with the existing picker and flags.
7. **Code in.** Clone the repo given as `sprs -i <project> [owner/repo|URL]`.
   If omitted and the current directory is a git clone, its `origin` is used;
   a teammate with no local checkout passes it explicitly. The clone lands at
   the same path incs uses for the workspace, created with `box_root` and
   chowned to `$BOX_USER`. Private repos need gh-auth, so that plugin is
   default-on for this backend. See Code and credentials.
8. **Shell.** `sprite console -s <name>`, or run the agent with
   `sprite exec --tty`. Sessions are detachable (Ctrl-\\) and reattach with
   `sprite sessions attach`. Both must be login shells that read `.zshenv`,
   or `set-env` secrets never reach the agent; the spike checks (item 8), and
   if they aren't, `box_user` and the agent launch wrap the command in
   `sh -lc`.

A failed build offers to `sprite destroy --force` the half-made Sprite, as
`incus.init`'s exit trap does.

### Egress baseline

Ships as `policies/sprite-baseline.json`:

```json
{ "rules": [ { "include": "defaults" } ] }
```

plus the hosts in the egress-allowlist design's baseline that `defaults`
doesn't cover; the builder diffs the two.

**Open (Chad):** provisioning runs under the policy, so installer hosts
(`claude.ai`, `cli.github.com`, `download.docker.com`, GitHub raw and release
URLs, apt mirrors) must be allowed somewhere. Options: (1) each plugin
declares `PLUGIN_EGRESS_HOSTS`, the tool merges them into the Sprite's policy,
and they stay allowed so the tool keeps working at runtime — the author's
recommendation; (2) the shipped baseline allows every installer host; (3)
widen during provisioning and tighten before the shell opens, which can leave
a failed build open. Base provisioning's own hosts (apt, oh-my-zsh) go in the
baseline under any option.

Per-Sprite extras come from
`--allow host` at create time and `sprs allow <name> <host>` afterwards. The
tool resets, never appends blindly: it reads the current policy, merges, and
posts the whole document. `--allow-all` writes `{"rules": []}` (unrestricted)
and prints a warning; it exists for the report-mode case the Incus design
also has.

### Code and credentials

Workspaces come in by `git clone` inside the Sprite, not by copying a local
directory. *(Chad)* Nothing from the teammate's disk is uploaded, so the
`.env` scan doesn't run on this backend.

**Phase 1:** the gh-auth plugin as today: a fine-grained token scoped to one
repo, pasted at a prompt, stored in the Sprite's `.zshenv`. Expiry recommended
in the prompt.

**Phase 2, gated on the spike:** a GitHub Connector per teammate, authorised
once in the Sprites dashboard with their own GitHub login and granted to
Sprites named `<user>-*`. Code goes in and `gh` works through the gateway
URL, and no GitHub token ever enters a Sprite. If git over the gateway works,
this becomes the default and gh-auth stays as the fallback.

Claude Code: each teammate runs `/login` in their own Sprite with their own
subscription. Sprites have no Anthropic Connector, and Anthropic's terms want
each person on their own subscription, so there's nothing to centralise.

Other secrets (`sprs set-env`) land in `.zshenv`, as incs does, with the same
stdin and `%q` handling.

### Trust model, stated plainly

Everyone in the Fly org holds an org token. With it, anyone can
`sprite exec` into anyone's Sprite and read what's inside: the Claude login,
the GitHub token in phase 1, any `set-env` secret. This is the trust model of
a shared server, and it's acceptable for this team. *(Chad)* The design
reduces what's at stake rather than pretending otherwise: Connectors keep
GitHub tokens out of Sprites, Claude sessions are revocable from
claude.ai, and the README says this in one sentence so nobody is surprised.

Sprite URLs are reachable by org members by default (`url_settings.auth:
sprite`). `private_access` can be `admins` or `organization`; the tool sets
the narrowest value that still lets the owner reach their own Sprite. The
builder verifies which that is for a non-admin member.

The agent inside a Sprite cannot change its policy. Only the teammate, from
their laptop, can, through `sprs allow`. Same as incs today, where the host
user is trusted and the container isn't.

### Lifecycle commands

`sprs` mirrors the incs commands that make sense:

| Command | Does |
|---|---|
| `sprs -i <project> [flags]` | boot sequence above |
| `sprs <name>` / `sprs shell <name>` | `sprite console`, waking it |
| `sprs list` | own Sprites with `cold` / `warm` / `running`, so the team can see who holds the concurrency slots |
| `sprs destroy <name>` | `sprite destroy` after confirmation |
| `sprs allow <name> <host>…` / `sprs policy <name>` | edit and show network policy |
| `sprs set-env <name> NAME` | prompt for the value, write `.zshenv` |
| `sprs checkpoint <name> [comment]` / `sprs restore <name> <id>` | thin wrappers; restore warns that it discards everything since |

Not in scope: `update-all`, `kill-all` (Sprites sleep by themselves), cron and
notify snippets, templates (`--from`). Templates may come back as "restore a
checkpoint into a new Sprite" if the platform supports it; the spike checks.

### Concurrency

The cap is per org and shared: 3 Sprites awake on pay-as-you-go, 10 on the
$20 plan. The team should be on the $20 plan. `sprs list` shows what's awake;
`sprs -i` prints a clear message when create fails on the cap.

## Spike before build

A hand-run script, `tests/sprite/spike.sh`, in the style of
`tests/host/egress_spike.sh`, creates a throwaway Sprite and reports:

1. `sudo -n true` works for `sprite`; `whoami` and `$HOME` as expected.
2. A heredoc through `sprite exec -- bash -s` arrives intact, including a
   payload over 64 KB, and the exit code propagates.
3. Network policy set via `sprite api`, read back from
   `/.sprite/policy/network.json`, and a blocked host fails fast.
4. Docker: `sudo apt install docker.io`, `docker run hello-world`, with
   privileges `standard` and then `privileged`. Decides the docker and
   supabase-serve rows above.
5. `private_access: admins` vs `organization` as seen by a non-admin member.
6. GitHub Connector: `gh api user` and `git clone` through the gateway URL.
   Decides phase 2.
7. Whether a checkpoint can seed a new Sprite.
8. Whether `sprite console` and `sprite exec --tty -- <cmd>` run a login
   shell for `sprite` that reads `.zshenv`, and whether `chsh -s $(which zsh)`
   sticks. Decides the `sh -lc` wrapping in step 8.

Boxen's script adds two checks: 9, which path form `sprite api` takes for a
Sprite's own resources, and 10, that `sprite list --prefix` finds the
Sprite create made.

Its findings go in a Review log at the bottom of this document before the
plan is written.

## Delivery

A stack of small PRs, in the repo's usual way:

1. The plugin contract: `box_root`, `box_user`, `box_set_env` defined by the
   Incus backend; the shared provisioning code extracted from `incus.init`;
   all 19 plugins migrated. No behaviour change on Incus; `tests/` must pass
   unchanged.
2. `sprite.init`, `sprs`, `policies/sprite-baseline.json`, the spike script.
3. README section for teammates; `install_shortcuts` links `sprs`.
4. Phase 2 (Connectors) if the spike passes.

For Boxen the stack is: this document and the spike; the guest scripts,
plugins, contract and baseline; the launcher's switch from sbx to Sprites;
the README, install and AGENTS.md. Phase 2 waits on the spike.

## Left to the builder

- Exact `box_user` implementation on Incus that preserves stdin and the login
  environment (`su -` vs `runuser`), and how `$BOX_HOME` is resolved.
- Whether to work around the 64 KB early-output bug.
- Test strategy for the Sprites backend with no Sprite: a fake `sprite`
  binary on PATH, as the existing tests fake `incus`, if they do.
- Diff between Sprites `defaults` and the egress-allowlist baseline.

## Non-goals

- Chad's own daily use. incs on Incus stays the primary tool; the network
  isolation stack on `feat/net-bridge` continues for Linux hosts.
- Managing Fly org membership or billing from the tool.
- Windows hosts.
- Running Sprites from CI or from Chad's hosted agents.

## Review log

2026-10-29, builder check (fresh reviewer, no author contact). Six questions.
Settled as author's calls: extract shared provisioning rather than copy it;
`sprs -i <project> [repo]` with cwd-origin fallback and gh-auth default-on;
`standard` privileges with `PLUGIN_PRIVILEGES` override and `BOX_BACKEND`
branches for backend-only steps; a stored handle instead of a Fly username;
spike item 8 for the login-shell question. Raised to Chad: where installer
hosts are allowed (Egress baseline, "Open").

2026-10-29, Boxen build. The spike has not run: it needs a laptop logged in
to the team's Fly org, which the build machine is not. Builder's calls for
"Left to the builder": no Incus `box_user`; `BOX_HOME` is `/home/sprite`;
early output over 64 KB is accepted as lost chatter, since every install
step's success is its exit code; the tests fake `sprite` on PATH; and
because Fly does not publish what `defaults` covers, the baseline lists base
provisioning's hosts explicitly, which is harmless if `defaults` already
has them.

2026-10-29, first spike run (Chad's laptop, Sprite version 0.0.4). Passed:
1, 2 (100 KB of stdin intact; 200 KB of immediate output lost, sprites-go#51,
as expected), 9 (the `sprite api -s NAME` form), 3's enforcement (a host
outside the policy is REFUSED in 1s, an allowed one and every baseline host
resolve; the Sprite cannot write its policy file), 7 and 10. Failed:
- 3's read-back: the Sprite had no `/.sprite/policy/network.json` at all,
  though Fly documents it, so every `lock_down` would have destroyed its
  Sprite. The launcher now reads the policy back from the API (a GET of
  `/policy/network`), and from the inside copy only where one exists. The
  API only shows Fly saved the policy, so `lock_down` also looks up a real
  host the policy does not allow (`example.org`, or the next candidate)
  inside the Sprite and fails if it resolves: enforcement is at DNS.
- 4: under `privileged`, dockerd booted (overlayfs, containerd) and the pull
  failed only on DNS: Docker Hub's blobs came from
  `production.cloudfront.docker.com`, which `defaults` does not cover and the
  docker plugin misspelt as `cloudflare`. The plugin now allows both. The
  service failed because `dockerd` is not at `/usr/sbin/dockerd`; the guest
  script now finds it on PATH. Under `standard`, dockerd left no log; the
  docker plugin asks for `privileged`, so this is recorded, not chased.
Open: 5 and 8 are manual; 6 was skipped.
