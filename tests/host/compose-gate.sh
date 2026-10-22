#!/usr/bin/env bash
# Task 1 gate (local): does composing v3/boxen onto each workload keep the
# workload's own system intact? For Docker's pinned Claude and Codex and
# Boxen's own shell, it makes a bare sample and one composed with
# v3/boxen, then compares them. A missing bare package, a dirty dpkg, or a
# different os-release fails the gate: fix the base before building the
# full image. Needs sbx, Docker with buildx, and jq. Run from anywhere:
#   bash tests/host/compose-gate.sh
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/../.." || exit 2
gate_begin compose-gate

TEMPLATE=docker/sandbox-templates:shell-docker
PINNED_BASE="$(sed -n 's/^FROM docker\/sandbox-templates:shell-docker@//p' v3/boxen/boxen.dockerfile)"
# Index digests of the pinned workload tags, read from the registry on
# 2026-10-21. A moved tag means the evidence no longer describes the image.
CLAUDE=docker.io/docker/sbx-kit-claude:2.1.267
CLAUDE_DIGEST=sha256:f3136cac8739534ba89d2bc0026b4f5dcfc2ca07e17947a9108dc5aabb176522
CODEX=docker.io/docker/sbx-kit-codex:0.155.1
CODEX_DIGEST=sha256:f808ef79b5aae10dcfd896dc898e16cbfd806bcd16c9699d208ccb99001eaf76

index_digest() { docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' | jq -r .digest; }
packages() {
  sbx exec "$1" dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' | LC_ALL=C sort > "$GATE_DIR/compose-$1.packages"
}
missing_from() { LC_ALL=C comm -23 "$GATE_DIR/compose-$1.packages" "$GATE_DIR/compose-$2.packages"; }

say "=== 1. pinned images"
expect 'shell-docker tag still resolves to the pinned base' "$PINNED_BASE" index_digest "$TEMPLATE"
expect 'Claude tag still resolves to the recorded digest' "$CLAUDE_DIGEST" index_digest "$CLAUDE"
expect 'Codex tag still resolves to the recorded digest' "$CODEX_DIGEST" index_digest "$CODEX"

for pair in "claude:$CLAUDE" "codex:$CODEX" "shell:./v3/shell"; do
  kind="${pair%%:*}"; workload="${pair#*:}"
  bare="v3g-bare-$kind"; composed="v3g-boxen-$kind"
  say "=== 2. $kind: bare and composed samples"
  create_sandbox "$bare" -- sbx create --name "$bare" "$workload"
  create_sandbox "$composed" -- sbx create --name "$composed" --kit ./v3/boxen "$workload"
  for sample in "$bare" "$composed"; do
    must "start $sample" sbx run --detached --name "$sample"
    say "=== 3. $sample"
    record "os-release $sample" sbx exec "$sample" cat /etc/os-release
    record "staged FROM lines and context $sample" sbx exec "$sample" sh -c \
      'grep -h ^FROM /usr/share/sandbox/kit/*/kit.dockerfile; grep -h agent-context /usr/share/sandbox/kit/*/kit.yaml'
    record "agent user $sample" sbx exec "$sample" id agent
    record "groups $sample" sbx exec "$sample" getent group docker _sudo
    check "package inventory $sample" packages "$sample"
  done
  [[ "$kind" != claude ]] || record "Claude's seeded settings (for Task 3)" sbx exec "$bare" cat /home/agent/.claude/settings.json

  say "=== 4. $composed"
  check "tools on PATH in $composed" sbx exec "$composed" zsh -lc 'mise --version && node --version && go version && command -v gh docker'
  check "no standing sudo in $composed" sbx exec "$composed" bash -c '! sudo -n true'
  expect "env line added once in $composed" 1 sbx exec "$composed" grep -c boxen/env.sh /etc/sandbox-persistent.sh
  expect "env.sh sourced twice adds mise once in $composed" 1 sbx exec "$composed" sh -c \
    '. /etc/boxen/env.sh; . /etc/boxen/env.sh; echo "$PATH" | tr : "\n" | grep -c mise/shims'
  expect "dpkg --audit clean in $composed" "" sbx exec --user root "$composed" dpkg --audit
  check "apt-get check in $composed" sbx exec --user root "$composed" apt-get check
  expect "every bare $kind package kept at its version" "" missing_from "$bare" "$composed"
  say "=== 5. $kind: same system"
  expect "os-release unchanged by v3/boxen ($kind)" "$(sbx exec "$bare" cat /etc/os-release </dev/null 2>/dev/null)" \
    sbx exec "$composed" cat /etc/os-release
done

say "=== 6. sbx kit validate"
record 'sbx kit validate ./v3/boxen' sh -c '"$0" kit validate ./v3/boxen; echo "exit $?"' "$SBX"
gate_end
