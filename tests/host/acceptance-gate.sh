#!/usr/bin/env bash
# The cutover's acceptance run: every v3 host gate, once, on a clean,
# committed revision, as one result. Passes from before a source or image
# change do not count, so this repeats them all. Preconditions come first and
# each ends the run, so nothing expensive starts after one fails. Several
# hours; the cold build dominates. Needs everything the gates need. Run from
# anywhere:
#   bash tests/host/acceptance-gate.sh
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/../../lib/pins.sh"
cd "$(dirname "$0")/../.." || exit 2
gate_begin acceptance-gate

GATES="compose-gate.sh tools-gate.sh mixins-gate.sh launcher-gate.sh smoke-gate.sh update-gate.sh"
BASE="$(sed -n 's/^FROM \(docker\/sandbox-templates:shell-docker@sha256:[0-9a-f]*\).*/\1/p' v3/boxen/boxen.dockerfile)"
index_digest() { docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' | jq -r .digest; }

say "=== 1. preconditions"
must 'clean tree' test -z "$(git status --porcelain)"
record 'revision' git rev-parse HEAD
must 'the Dockerfile pins its base by digest' test -n "$BASE"
record 'base image' printf '%s\n' "$BASE"
for agent in claude codex grok; do
  check "$agent mixin tag still resolves to the digest in lib/pins.sh" \
    sh -c 'test "$(docker buildx imagetools inspect "$0" --format "{{json .Manifest}}" | jq -r .digest)" = "$1"' \
    "$(mixin_ref "$agent")" "$(mixin_digest "$agent")"
done
# A moved tag means the gates below would test something else: stop here.
[[ "$GATE_FAILED" == 0 ]] || gate_abort

say "=== 2. every gate, each with its own log"
for gate in $GATES; do
  check "$gate" bash "tests/host/$gate"
done

say "=== 3. the images the builds consumed"
record 'base image RepoDigests' docker image inspect --format '{{join .RepoDigests ","}}' "${BASE%@*}"
for agent in claude codex grok; do
  record "$agent mixin RepoDigests" docker image inspect --format '{{join .RepoDigests ","}}' "$(mixin_ref "$agent")"
done
record 'locally built kit images' sh -c "docker image ls --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}' | grep sbx-kit-src"
gate_end
