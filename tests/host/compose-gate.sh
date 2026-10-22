#!/usr/bin/env bash
# Task 1 gate (local): does Boxen's workload come up alone and with each of
# Docker's agent mixins, with its tools, no standing sudo, a clean package
# database, and the agent BOXEN_AGENT names? sbx refuses a composition whose
# kits change the same file, so a create that fails here names the clash in
# its daemon log. Needs sbx, Docker with buildx, and jq. Run from anywhere:
#   bash tests/host/compose-gate.sh
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/pins.sh"
cd "$(dirname "$0")/../.." || exit 2
gate_begin compose-gate

TEMPLATE=docker/sandbox-templates:shell-docker
PINNED_BASE="$(sed -n 's/^FROM docker\/sandbox-templates:shell-docker@//p' v3/boxen/boxen.dockerfile)"
index_digest() { docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' | jq -r .digest; }

say "=== 1. pinned images"
expect 'shell-docker tag still resolves to the pinned base' "$PINNED_BASE" index_digest "$TEMPLATE"
for agent in claude codex grok; do
  expect "$agent mixin tag still resolves to the recorded digest" "$(mixin_digest "$agent")" index_digest "$(mixin_ref "$agent")"
done

for agent in shell claude codex grok; do
  name="v3g-$agent"
  kit=()
  [[ "$agent" == shell ]] || kit=(--kit "$(mixin_ref "$agent")")
  say "=== 2. $name: Boxen's workload${kit[1]:+ with ${kit[1]}}"
  create_sandbox "$name" -- sbx create --name "$name" --cpus 4 --memory 4g --env "BOXEN_AGENT=$agent" "${kit[@]}" ./v3/boxen
  must "start $name" sbx run --detached --name "$name"
  expect "BOXEN_AGENT reaches $name" "$agent" sbx exec "$name" printenv BOXEN_AGENT
  check "the agent can write its workspace in $name" sbx exec "$name" sh -c 'test -w /home/agent/workspace'
  check "Boxen's checks pass in $name" sbx exec "$name" env "BOXEN_AGENT=$agent" bash /usr/local/share/boxen/check.sh
  check "tools on PATH in $name" sbx exec "$name" zsh -lc 'mise --version && node --version && go version && command -v gh docker'
  check "no standing sudo in $name" sbx exec "$name" bash -c '! sudo -n true'
  expect "env line added once in $name" 1 sbx exec "$name" grep -c boxen/env.sh /etc/sandbox-persistent.sh
  expect "dpkg --audit clean in $name" "" sbx exec --user root "$name" dpkg --audit
  check "apt-get check in $name" sbx exec --user root "$name" apt-get check
  if [[ "$agent" != shell ]]; then
    check "$agent runs from a login shell in $name" sbx exec "$name" bash -lc "$agent --version"
  fi
  record "context files in $name" sbx exec "$name" sh -c \
    'ls -la /home/agent/*.md /home/agent/.claude/CLAUDE.md /home/agent/.codex/AGENTS.md /usr/share/sandbox/kit/*/ 2>&1'
  record "os-release $name" sbx exec "$name" cat /etc/os-release
  # Free its memory before the next box; the exit trap removes it.
  check "stop $name" sbx stop "$name"
done

say "=== 3. sbx kit validate"
record 'sbx kit validate ./v3/boxen' sh -c '"$0" kit validate ./v3/boxen; echo "exit $?"' "$SBX"
gate_end
