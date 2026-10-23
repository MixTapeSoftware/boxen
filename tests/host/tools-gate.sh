#!/usr/bin/env bash
# Task 2 gate (local): does the workload with every tool baked in build, come
# up with Docker's Claude mixin, and pass check.sh? It records the cold build
# time and the image size, then changes only check.sh and records the rebuild
# time, to show the installer steps come from the cache. Needs sbx, Docker
# and jq; the cold build takes 15 to 30 minutes. Run from anywhere:
#   bash tests/host/tools-gate.sh
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/../../lib/pins.sh"
cd "$(dirname "$0")/../.." || exit 2
gate_begin tools-gate

PROBE=v3/boxen/scripts/check.sh
SAVED="$GATE_DIR/tools-gate.check.sh"
# Puts check.sh back byte for byte, also when the gate is interrupted. Never
# git checkout: that would throw away uncommitted work in the file.
cleanup() { [[ ! -f "$SAVED" ]] || { cp -p "$SAVED" "$PROBE" && rm -f "$SAVED"; }; }
create_with_claude() { sbx create --name "$1" --cpus 4 --memory 4g --env BOXEN_AGENT=claude --kit "$(mixin_ref claude)" ./v3/boxen; }

say "=== 1. cold build"
started="$(date +%s)"
create_sandbox v3-tools -- create_with_claude v3-tools
say "cold create took $(( $(date +%s) - started )) s"
record 'image sizes' sh -c '"$0" image ls --format "{{.Repository}}:{{.Tag}} {{.Size}}" | grep -i -e sbx -e boxen || true' "$DOCKER"

say "=== 2. every tool"
must 'start v3-tools' sbx run -d --name v3-tools
check "Boxen's checks pass" sbx exec v3-tools env BOXEN_AGENT=claude bash /usr/local/share/boxen/check.sh
record 'check.sh output' sbx exec v3-tools env BOXEN_AGENT=claude bash /usr/local/share/boxen/check.sh
check 'stop v3-tools' sbx stop v3-tools

say "=== 3. rebuild after changing only a runtime script"
must 'save check.sh' cp -p "$PROBE" "$SAVED"
printf '# cache probe %s\n' "$(date +%s)" >> "$PROBE"
lines_before="$(wc -l < "$GATE_LOG")"
started="$(date +%s)"
create_sandbox v3-tools2 -- create_with_claude v3-tools2
say "rebuild took $(( $(date +%s) - started )) s"
must 'restore check.sh' cp -p "$SAVED" "$PROBE"
check 'check.sh is back as it was' cmp -s "$SAVED" "$PROBE"
rm -f "$SAVED"
record 'cached steps in the rebuild output' sh -c 'tail -n +"$0" "$1" | grep -c CACHED || true' "$((lines_before + 1))" "$GATE_LOG"
gate_end
