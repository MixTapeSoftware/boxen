# Validation record

Tested on 2026-10-12 with SBX 0.47.0, Linux amd64, and nested KVM. The host
initially had 3.8 GiB RAM; resumed testing used 5.8 GiB, without swap. This is
a prototype, not a completed cross-platform or authenticated integration test.

The Matt Pocock skills kit was later removed, so no kit is selected by default.

## Checks that passed

- All 17 descriptors passed the installed, authenticated `sbx kit validate`.
  They also passed Docker's pinned upstream v2 parser through
  `tests/validate-upstream.sh`.
- `bash tests/run.sh` passed shell syntax checks and 29 tests covering argument
  handling, plugin composition, copy transport, failure behavior, secret sources,
  and kit structure. This was rerun successfully after the host restart.
- Nine isolated Tailscale tests execute the control script with fake CLI and
  temp-file helpers. They cover all seven routes, port validation, daemon
  timeout handling, route failures, and private auth-file cleanup on success,
  failure, and empty input. No VM, real daemon, or network is used.
- The 15 CLI tests also passed using a locally built Bash 3.2.57, before restart.
- Relocating the project to a directory containing spaces and invoking the
  launcher from `/` produced kit paths within the relocated checkout.
- Every installer, including Grok, completed in a disposable ordinary Docker
  container using Docker's public shell image. That container was removed.
- A real mountless SBX environment, `boxen-check`, completed all install
  hooks with the full non-agent plugin preset.
- Its 28 runtime checks passed: development tools, shell, editor configuration,
  shared skills, RTK hooks, Tailscale socket, and browser tools. Both Playwright
  and ChromeDriver launched real browsers and checked a page title.
- The sandbox's private Docker Engine (29.8.1) successfully pulled and ran
  `hello-world`.
- A local HTTP server was reachable through SBX's loopback port publishing.
  The server and mapping were removed after the check.
- `bash tests/sbx-smoke.sh boxen-check` passed: a deliberate stop/start
  preserved a file on the dedicated Tailscale volume, left exactly one
  `tailscaled` process, and passed all 28 runtime checks again.
- Separate native Grok, Claude/RTK, and Codex environments completed provisioning
  and smoke checks with core, RTK, Matt Pocock skills, and GitHub configuration.
  Each test used 1 GiB and two CPUs, with no other sandbox running.
- All three workload entrypoints accepted a `--version` launch. A direct
  Codex version invocation additionally returned `codex-cli 0.149.1`.
- Each native workload test copied binary and hidden files into
  `/home/agent/workspace`, verified that as the default execution directory,
  and confirmed guest edits left the host fixture unchanged without a source
  mount. Successful test sandboxes were stopped and removed.

The base image was `docker/sandbox-templates:shell-docker`, digest
`sha256:1560168ac5fb9ce23d413c878349334c5845c07e264cd675d7867f0c78ad1761`.
It supplied Ubuntu 26.04.1. Some installers follow upstream latest releases;
the same kit source can therefore resolve different tool versions later.

## Resource incidents and safeguards

Starting a second, 1 GiB test microVM while the full environment was running
exhausted the outer VM's memory. The Linux OOM killer terminated a VM process,
and the user's sessions were disrupted. The host was subsequently restarted.
Validation should have been sequential with explicit memory headroom checks.
The wrapper currently delegates sizing to SBX and has no aggregate memory guard.

SBX's default memory allocation is half the host RAM, within its supported
limits; it does not reserve that amount for the user's other applications.
Do not run this validation concurrently with another sandbox on a small host.
Use explicit `--memory` and `--cpus` values when appropriate, and account for
host applications and VM overhead as well as the guest allocation.

After the host restart, the SBX daemon was stopped. Work resumed when the user
requested it, using one memory-capped sandbox at a time. Earlier temporary logs
under `/tmp` were lost in the restart; this record summarizes those observed
command results. Resumed logs are in ignored `local/validation/`.

The first resumed Codex attempt exhausted disk space while unpacking system
packages. Its base image required substantially more storage than the other
workloads. Provisioning failed and SBX removed the failed environment. Removing
the older, disposable full-kit sandbox recovered space; Codex then passed on
retry. No user project directories or personal Docker containers were removed.

`tests/workload-smoke.sh` now refuses concurrent sandboxes, caps each guest at
1 GiB/two CPUs, and requires 3 GiB available host memory on Linux. It checks for
3 GiB free disk with a cached base image, or 6 GiB when downloading a new one.
These are test preflights, not aggregate resource limits in the main launcher.
The full-kit sandbox and all temporary agent test environments were removed
after validation. The large Claude and Codex image caches downloaded for these
tests were also removed. No test sandbox is left running.

## Changes later on 2026-10-12

A review led to these changes: a command line with short aliases, an
interactive kit selector, Matt Pocock skills as the only default kit, a
workspace volume, no host mounts by default (`--mode mount|clone` and
`--skills` opt in), no standing sudo, no Tailscale operator, no startup reapply
of serve routes, fine-grained GitHub tokens by default, a `.env` gate, a memory
guard, existence checks before every named command, pinned and checksummed
downloads, and a host installer that can add Chadmux.

What was checked without starting a microVM:

- `bash tests/run.sh`: 69 tests passed with Bash 5.2.21 and again with a
  locally built Bash 3.2.57 (`TEST_BASH`). They drive the kit selector through
  a pseudo-terminal and run the installer against a temporary home with fake
  git and tmux. This found that a failing `command`
  builtin inside a function exits under `set -e` in Bash 3.2 even within `||`;
  the `sbx()` wrapper no longer uses it.
- `tests/validate-upstream.sh`: all 18 descriptors, including the new
  workspace kit, passed Docker's pinned v2 parser.
- In a disposable Docker container from `docker/sandbox-templates:shell-docker`,
  the sudo policy removed the agent's sudo (`sudo -n true` asks for a password)
  while `boxen-sudo-session` gave a session `agent` with groups
  `agent docker _sudo` and working sudo. Docker's own
  `/etc/sudoers.d/proxyconfig` is mode 0644, so the policy validates only its
  own file with `visudo`.
- In the same kind of container, the changed installers ran end to end as root
  or UID 1000 in kit order: core, sudo policy, workspace, fzf-bat, just, glow,
  mermaid-ascii, overmind, rtkplus, Matt Pocock skills, Tailscale, gh-auth and
  1Password. Every checksum matched and every pinned version installed
  (Tailscale 1.104.1, op 2.30.0, Overmind 2.5.1, just 1.58.0, Glow 3.0.0,
  fzf 0.74.5, bat 0.26.1, Go 1.27.2). `check.sh` reported no failures, and
  `/workspace` linked to an agent-owned `/home/agent/workspace`. Chromium and
  nvChad were left out for disk space; their new checksums were confirmed by
  download. The container was removed.
- Checksums came from vendor checksum files where published (Tailscale,
  mermaid-ascii) and otherwise from direct downloads. Mason's registry confirms
  the six language-server binary names that `check` looks for.

Not yet run in a real sandbox: the workspace volume (including surviving
`sbx kit add`), sudo removal in the Claude and Codex images, the
consolidated network allowlists under sbx policy, and `net`, `env`, `update`,
`kill-all` and `status` against real sbx output. `tests/workload-smoke.sh` now
covers the first two.

## Still unverified

- **Skipped at the user's request:** further live Tailscale smoke tests,
  including daemon startup/restart, enrollment, authenticated node identity
  persistence, HTTPS certificates, and access from another tailnet device.
  The earlier runtime checks listed above preceded this scope change. Isolated
  code tests remain enabled; they do not prove end-to-end preview access.
- Real GitHub token injection, 1Password retrieval, agent authentication, and
  model calls. Host source commands and stdin transport were tested with fakes;
  no personal credentials were registered by the wrapper tests.
- Actual RTK hook execution during authenticated agent tool calls. Installers,
  hook files, and workload launch were checked; no model task was submitted.
- macOS hosts and arm64 execution. Architecture branches are implemented but
  were not runtime-tested here.
- Exporting an enrolled sandbox without its Tailscale identity. There is no
  template-export wrapper until that behavior is proven.

Nothing was published to a registry or created in Docker Cloud.

## 2026-10-21 cloud probes

Author-reported: these commands were run by Chad on a Linux host with
`sbx version: v0.47.0 0411f50ee4700fe7bd37e6e7e3aced563e850ca9` during the
session that produced `docs/superpowers/specs/2026-10-21-v3-kits.md`, and
their output was pasted into that session. They are not independently
reproduced; the v3 implementation plan's host steps reproduce them.

1. The v2 core kit fails to install in a cloud sandbox:

   ~~~
   $ sbx --cloud create claude --name boxen-test --kit ./kits/core
   ── CONFIGURE AGENT
      ✗ configure 2 kit(s) (7s)
   error: create cloud sandbox: failed_precondition: kit "boxen-core" failed to apply to sandbox sbx_001m5fycxw6jzmtj6abzgtky1qj: commands.install[0] exited with status 127
   ~~~

2. A v2 probe kit with one file under `files/home/.local/share/probe/hi.sh` and
   four install steps (`command -v bash || exit 5`, `test -d /home/agent ||
   exit 6`, `test -d /home/agent/.local || exit 7`, `test -f
   /home/agent/.local/share/probe/hi.sh || exit 8`, all as user `0`):

   ~~~
   error: create cloud sandbox: failed_precondition: kit "probe" failed to apply to sandbox sbx_001m5fyq8aec44q67z1md4ywzha: commands.install[3] exited with status 8
   ~~~

   With the last step changed to `|| true`, creation succeeded and the file
   was present afterwards:

   ~~~
   $ sbx --cloud exec probe ls -la /home/agent/.local/share/probe
   -rw-r--r--  1 agent agent    8 Oct 21 19:25 hi.sh
   ~~~

   Conclusion: the cloud applies a v2 kit's `files/home/` after
   `setup.install`, contrary to the kits-v2 execution order Docker documents.

3. A v3 probe mixin (`FROM scratch`, `COPY hi.sh /usr/local/share/probe/hi.sh`,
   one `lifecycle@1` install hook `test -f /usr/local/share/probe/hi.sh ||
   exit 8` as user `0`):

   ~~~
   $ sbx --cloud create docker.io/docker/sbx-kit-claude:2.1.267 --name probe3 --kit /tmp/probe3
      → build kit /tmp/probe3 (sbx-kit-src:probe3-abcd04ad4742)
   error: sbxcloud: invalid input: composing v3 kits from source is supported by `sbx --cloud run`; publish the kits to a registry to use them here

   $ sbx --cloud run docker/sbx-kit-claude --name probe3 --kit /tmp/probe3
   error: resolve kits: kit "docker/sbx-kit-claude": v3 kit descriptor: decode kit descriptor: yaml: unmarshal errors:   line 1: field name not found in type spec.plain

   $ sbx --cloud run docker/sbx-kit-claude:2.1.267 --name probe3 --kit /tmp/probe3
   (sandbox created; the install hook passed; Claude's TUI opened)
   ~~~

   After quitting Claude, `sbx --cloud ls` listed
   `sbx-kit-claude/probe3 ... running`, so a detached cloud sandbox keeps
   running without `long-running@1`. The untagged `docker/sbx-kit-claude`
   descriptor carries a field sbx v0.47.0 does not know; the pinned tag
   decodes.

Not exercised by these probes: a cloud sandbox stopping or expiring, cloud
`exec --user`, credentials, ports, and any v3 kit with a Dockerfile larger
than one file.

### Later on 2026-10-21: a second cloud attempt (reported second-hand)

Codex's second review of the v3 plan cites a terminal transcript from Chad
that is not yet in this repository. As reported there: `sbx --cloud run`
with `--allow-network '*'` was rejected, the CLI asking for `"**"` to mean
every host; and a run of the pinned `docker/sbx-kit-claude:2.1.267` reported
that the cloud could not supply `com.docker.sandbox/volume@1`, selected a
template fallback, warned that five Claude storage directories would use
sandbox disk, and began creating a bake sandbox, which was interrupted with
Ctrl-C. The CLI version for that attempt was not recorded. Paste the
transcript here when available; until then it establishes the rejected
wildcard and the attempted fallback, not the fallback's outcome.

### 2026-10-21 cloud probe: stop-at-expiry and SSH forwarding (passed)

`tests/host/cloud-probe.sh` run by Chad on the Linux x86_64 host with
`sbx version: v0.47.0 0411f50ee4700fe7bd37e6e7e3aced563e850ca9`, output
pasted into the session (log: `local/validation/cloud-probe-20261021-164257.log`
on the host). Workload: `docker.io/docker/sbx-kit-claude:2.1.267` alone, no
Boxen kits.

- `sbx --cloud run --detached --name v3-probe --ttl 1h --on-timeout stop` was
  accepted and the sandbox was `running` immediately; the row showed
  `"template": "tmpl_001m5gc8s10m6ve8axt83ty4s4b"`, the same template id as an
  earlier run, so the cloud bakes one template per workload and reuses it.
  Default size 2 CPUs / 4096 MiB. `ttl --json`: `expires_in_seconds: 3592`,
  `max_remaining_seconds: 86395`.
- `sbx --cloud exec` runs as `uid=1000(agent)`, groups `agent sudo docker`:
  Docker's cloud sandbox gives the agent user the `sudo` group by default.
- `sbx --cloud setup ssh` wrote a config with `hostname sbx_gateway` and
  `proxycommand "/usr/bin/sbx" --cloud ssh-connect '%r' %h %p`; it provisions
  a per-sandbox ED25519 key and certificate under
  `~/.ssh/sandboxes/<sandbox-id>/`. `ssh <sandbox-id>@sbx_cloud id` printed the
  agent user.
- A local forward (`ssh -f -N -M -S <sock> -L 127.0.0.1:18000:127.0.0.1:8000`)
  reached a `python3 -m http.server` inside the sandbox: HTTP 200, and the
  laptop listener was bound to `127.0.0.1:18000` only.
- `sbx --cloud stop` settled to `stopped` in 28 s; `exec cat` of the marker
  file resumed the sandbox and printed it; the id was unchanged and the TTL
  started a new one-hour period.

Not covered by this probe: Codex and Grok in the cloud, and Boxen's own
kits composed in the cloud (Task 1's `cloud-compose-gate.sh`). A real
server-side expiry is covered by the next section.

### 2026-10-22 cloud probe: a real five-minute expiry (passed)

`tests/host/expiry-probe.sh` run by Chad on the same host and sbx build
(`v0.47.0 0411f50ee4700fe7bd37e6e7e3aced563e850ca9`), output pasted into the
session; log `local/validation/expiry-probe-20261021-192715.log` on the host.
Workload: `docker.io/docker/sbx-kit-claude:2.1.267` alone, no Boxen kits.
The script creates the sandbox with `--ttl 5m --on-timeout stop`, writes a
marker file, polls `sbx --cloud ls --json` every ten seconds until the row
is `stopped` or missing, then resumes it by reading the marker.

- `--ttl 5m` is accepted: `created_at 02:27:23Z`, `expires_at 02:32:20Z`;
  `ttl --json` right after creation: `expires_in_seconds: 291`,
  `max_remaining_seconds: 86394`.
- An `exec` does not extend the TTL (`expires_at` unchanged after it).
- Status went `running`, then `stopping` at 02:33:14Z (54 s past
  `expires_at`), then `stopped` at 02:34:09Z. The row stayed listed with
  the same id. With `--on-timeout stop`, a real server-side expiry stops the
  sandbox and keeps it, which is what `boxen create --cloud` relies on.
- `exec cat` of the marker resumed it and printed `survived`; `running`
  again at once; same id; `ttl --json` after the resume showed a fresh
  period (`expires_in_seconds: 296`).
- The 24-hour cap keeps counting while stopped: `max_remaining_seconds`
  went from 86394 to 85987 across the 407 s between the two readings, five
  minutes of which the sandbox was stopped. Every cloud sandbox therefore
  reaches Docker's cap about 24 hours after creation whatever its state.
  What happens then (does a resume still work? is it removed?) is not
  verified. A box kept with `BOXEN_PROBE_KEEP=1 bash tests/host/expiry-probe.sh`
  and checked the next day answers it.
- Docker's wording at create time for Claude's five `volume@1` paths: "kit
  storage at /home/agent/.claude/... is not provisioned for cloud sandboxes;
  those paths live on the sandbox's own disk instead". Plain disk.
- Earlier the same night, by hand: a box created at about 00:35Z with the
  same flags was found and resumed by `sbx --cloud run --detached --name`
  an hour later (`MAX remaining: 22h57m` against 86394 s for a fresh box),
  the first hint of the same result. A pasted `rm --force` removed it
  before that could be confirmed, hence the script.
- A second run of the script at 03:03Z (`sbx_001m5gs15c81yj4mkxh5dsm64jw`,
  `created_at 03:03:50Z`) showed something the first did not: after the marker `exec`, `expires_at` moved
  from 03:08:47Z to 04:03:59Z, `expires_in_seconds: 3599`, that is a new
  one-hour period from the moment of the exec, Docker's server default
  rather than the 5 minutes the box was created with. The first run's exec
  left the TTL alone, and Docker's docs say nothing about `exec` touching
  it. Unexplained; seen once. Consequence for Boxen: `create --cloud`
  re-reads the TTL after its own exec steps and extends it back to the
  configured value with `sbx --cloud ttl +Nm NAME` when it came up short
  (plan, Task 6). The probe script now records the TTL after a second exec
  and sizes its wait from the live `expires_at`. That run was still
  `running` at 03:19Z, as the moved expiry predicts; the script gave up
  there and, run without `BOXEN_PROBE_KEEP=1`, removed the box. The
  24-hour cap question is still open: `bash tests/host/day2-probe.sh start`
  creates a box and records it; `bash tests/host/day2-probe.sh check` a day
  later writes `local/validation/day2-probe.result` (`kept`, `unresumable`
  or `gone`), which the acceptance run requires.
- `day2-probe.sh start` ran at 03:48Z: `sbx_001m5gvkgy21f6r51kktsy5tpbv`,
  `created_at 03:48:49Z`, `--ttl 5m --on-timeout stop`, marker written,
  `expires_at 03:53:46Z` read after the exec, so this time the exec did not
  move the TTL (one reset in three runs). An immediate `check` refused with
  "Too early", as designed. The check is due after 2026-10-23T04:03:49Z.
- Docker's dashboard at about 03:50Z listed `day2-probe` as Running, 3 min
  left, On Timeout "Stop", and a second box `expiry-probe` (from a
  `BOXEN_PROBE_KEEP=1` run of the expiry probe started about 03:44Z) as
  "Paused", no time left, On Timeout "Stop", age 6 min: a box that reached
  its five-minute expiry and was kept, shown as "Paused" where the CLI says
  `stopped`. Both bill no compute while stopped.
