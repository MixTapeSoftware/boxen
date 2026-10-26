#!/usr/bin/env bash
# Task 7 gate: does boxen update keep a v3 sandbox's packages whole? For
# Claude and Codex boxes made through ./bxn: every package installed before
# the update is still installed after it (a newer version is fine, and is
# recorded), dpkg and apt are clean, and the agent still runs. Then
# update-all, which sees only this gate's sandboxes: gate_begin gives ./bxn
# a registry of its own. Needs sbx, Docker with buildx, and jq. Run from anywhere:
#   bash tests/host/update-gate.sh
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/../.." || exit 2
gate_begin update-gate

# NAME FILE: Package<TAB>Version<TAB>Status, sorted bytewise for comm.
save_inventory() {
  sbx exec "$1" dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' </dev/null | LC_ALL=C sort > "$2"
}
# FILE: the names of installed packages; a newer version still counts.
installed() { awk -F'\t' '$3 == "install ok installed" { print $1 }' "$1" | LC_ALL=C sort; }
version_changes() {
  awk -F'\t' 'NR == FNR { was[$1] = $2; next } ($1 in was) && was[$1] != $2 { print $1 ": " was[$1] " -> " $2 }' "$1" "$2"
}

for agent in claude codex; do
  name="v3-upd-$agent"
  before="$GATE_DIR/$name.before.tsv" after="$GATE_DIR/$name.after.tsv"
  say "=== $name"
  # A rejected claim or a failed create ends the gate, so update never
  # touches a sandbox this gate did not make.
  create_sandbox "$name" -- ./bxn create "$name" --no-copy --agent "$agent" --plugins none --no-tui
  must "inventory before the update in $name" save_inventory "$name" "$before"
  check "./bxn update $name" ./bxn update "$name"
  must "inventory after the update in $name" save_inventory "$name" "$after"
  installed "$before" > "$before.names"; installed "$after" > "$after.names"
  expect "every package installed before is installed after in $name" "" comm -23 "$before.names" "$after.names"
  record "version changes in $name" version_changes "$before" "$after"
  expect "dpkg --audit clean in $name" "" sbx exec --user root "$name" dpkg --audit
  check "apt-get check in $name" sbx exec --user root "$name" apt-get check
  check "$agent still runs in $name" sbx exec "$name" bash -lc "$agent --version"
done

say "=== update-all"
check './bxn update-all (this gate'"'"'s sandboxes only)' ./bxn update-all
gate_end
