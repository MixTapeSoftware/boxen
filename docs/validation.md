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

## 2026-10-21 v3 kits

The v3 plan's host gates run on a machine with sbx and Docker; each writes
its log, with the sbx version, Docker server version and host, to
`local/validation/<gate>.log` there. This section records what has passed and
what is still to run. Earlier passes do not count once the image or the
source changes: the cutover's acceptance run repeats every gate on the final
revision.

Pins:

- Base image `docker/sandbox-templates:shell-docker@sha256:b178ca62ec2e79af2a044e3ec321bdb72188690e1c15d573ea5524b397554d3d`
  (Ubuntu 26.04), resolved from the registry on 2026-10-22; `compose-gate.sh`
  checks that the tag still resolves to it.
- Docker's agent mixins, by tag and index digest in `lib/pins.sh`: Claude
  2.1.267, Codex 0.155.1 and Grok 1.0.34, the newest that sbx v0.47.0 reads.

Passed on the host:

- 2026-10-22, sbx v0.47.0: the redesigned workload plus
  `sbx-kit-claude-mixin:2.1.267` assembled with no file collisions, and
  `claude --version` printed 2.1.267 (the smoke test in PR #4).
- 2026-10-23T00:52Z: `tests/host/compose-gate.sh`, 55 checks, 0 failed. The
  workload alone and with each agent mixin: tools on PATH, no standing sudo,
  the environment line once, a clean `dpkg --audit` and `apt-get check`, and
  each agent's `--version`.
- 2026-10-23T01:03Z: `tests/host/cloud-compose-gate.sh`, 21 checks, 0 failed.
  In Docker Cloud: sudo kept, a stop and resume with the marker, an SSH
  forward answering `200`, and a real five-minute expiry that stopped and
  kept the sandbox with its id.

Still to run (the command, then what it records):

- `bash tests/host/tools-gate.sh`: every baked tool, the cold build time,
  the image size and the rebuild time after a content change.
- `bash tests/host/mixins-gate.sh`: every Boxen mixin at once on Claude, RTK
  on Codex, the others on Grok, and a restart.
- `bash tests/host/launcher-gate.sh` (optionally with `BOXEN_OLD_SANDBOX`):
  the launcher end to end, including whether sbx v0.47.0's `kit validate`
  accepts v3 directories.
- `bash tests/host/cloud-gate.sh` (`GH_TEST_TOKEN`,
  `BOXEN_TEST_PRIVATE_REPO`, `BOXEN_CLOUD_POLICY_NOTE`; optionally
  `BOXEN_TEST_TS_KEY`): the upload time, the policy note and egress results,
  Docker inside a cloud box, the `sbx --cloud ttl +Nm` extension, and whether
  a secret set after creation applies live. Until it reports, `boxen env`
  says a cloud secret applies at the next start.
- `bash tests/host/expiry-gate.sh`: a real expiry of the launcher's composed
  Claude and its own shell box, then a resume through `./boxen`.
- `bash tests/host/smoke-gate.sh`: each agent with and without RTK, and the
  Tailscale restart check.
- `bash tests/host/update-gate.sh`: `boxen update` keeps every installed
  package on Claude and Codex boxes.
- `bash tests/host/day2-probe.sh start`, then `check` a day later: whether a
  stopped cloud box can be resumed past Docker's 24-hour cap. Its result file
  is an input to the cutover's acceptance run.
- `bash tests/host/acceptance-gate.sh`, last, on a clean committed revision:
  every gate above once, with the revision, the base and mixin digests and the
  day-2 result. The v2 kits are removed only after it passes; its summary goes
  here, and the README's retention sentence is written from the day-2 result.

Not run: Bash 3.2 (no Bash 3.2 binary in the development container; set
`TEST_BASH` to one and run `bash tests/run.sh`), arm64 hosts and macOS hosts.
