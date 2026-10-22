#!/usr/bin/env bash
# Does a cloud sandbox created with --on-timeout stop survive a real expiry?
# Creates one with a short TTL, waits for the server to expire it, then
# checks that it is stopped (not gone) and that a file written before the
# expiry is still there after a resume. Uses Docker's pinned Claude workload
# alone, so the result is about the cloud, not Boxen. Needs sbx (logged in,
# cloud plan), jq and GNU date. Takes about eight minutes. Exits 1 if a
# check failed. Never touches a sandbox it did not create.
#
#   bash tests/host/expiry-probe.sh                    # 5-minute TTL
#   BOXEN_PROBE_TTL=10m bash tests/host/expiry-probe.sh
#   BOXEN_PROBE_KEEP=1 bash tests/host/expiry-probe.sh   # keep it for the 24-hour check
set -uo pipefail
name="${1:-expiry-probe}"
workload="${BOXEN_PROBE_WORKLOAD:-docker.io/docker/sbx-kit-claude:2.1.267}"
ttl="${BOXEN_PROBE_TTL:-5m}"
sbx="${SBX_BIN:-sbx}"
project="$(cd "$(dirname "$0")/../.." && pwd)"
dir="${BOXEN_VALIDATION_DIR:-$project/local/validation}"
mkdir -p "$dir"
log="$dir/expiry-probe-$(date -u +%Y%m%d-%H%M%S).log"
failed=0
created=0
id=""

now() { date -u +%FT%TZ; }
say() { printf '%s %s\n' "$(now)" "$*" | tee -a "$log"; }
# check LABEL CMD...: PASS/FAIL by exit status; output goes to the log.
check() {
  local label="$1" out status; shift
  out="$("$@" 2>&1)"; status=$?
  printf '%s\n' "$out" >> "$log"
  if [[ "$status" == 0 ]]; then say "PASS $label"; else say "FAIL $label (exit $status)"; failed=1; fi
  return "$status"
}
# expect LABEL EXPECTED CMD...: exit 0 and stdout equal to EXPECTED.
expect() {
  local label="$1" expected="$2" out status; shift 2
  out="$("$@" 2>>"$log")"; status=$?
  printf '%s\n' "$out" >> "$log"
  if [[ "$status" != 0 ]]; then say "FAIL $label (exit $status)"; failed=1
  elif [[ "$out" == "$expected" ]]; then say "PASS $label"
  else say "FAIL $label (got: ${out:-<nothing>})"; failed=1; fi
}
# record LABEL CMD...: output to the log and screen; never fails.
record() { local label="$1"; shift; say "--- $label"; "$@" 2>&1 | tee -a "$log"; }
# wait_for LABEL SECONDS CMD...: retry once a second.
wait_for() {
  local label="$1" seconds="$2" i; shift 2
  for ((i = 0; i < seconds; i++)); do
    if "$@" >/dev/null 2>&1; then say "PASS $label (${i}s)"; return 0; fi
    sleep 1
  done
  say "FAIL $label (not within ${seconds}s)"; failed=1; return 1
}
# row: this sandbox's ls --json row, or nothing. Fails only if ls failed.
row() {
  local out
  out="$("$sbx" --cloud ls --json)" || return 1
  printf '%s' "$out" | jq -c --arg n "$name" '.sandboxes[] | select(.name == $n)'
}
status_is() { [[ "$(row | jq -r '.status')" == "$1" ]]; }
expires_at() { "$sbx" --cloud ttl --json "$name" | jq -r '.expires_at // empty'; }
epoch() { date -u -d "$1" +%s; }
cleanup() {
  if [[ "$created" != 1 ]]; then
    say "Nothing to remove: $name was not created by this run."
  elif [[ "${BOXEN_PROBE_KEEP:-0}" == 1 ]]; then
    say "Kept $name: it expires again and then sits stopped, billing no compute."
    say "Docker caps a sandbox at 24 hours from creation. After that, run:"
    say "  $sbx --cloud ls                                       # still listed?"
    say "  $sbx --cloud exec $name cat /home/agent/probe-marker   # does a resume still work?"
    say "  $sbx --cloud rm --force $name"
  else
    # Remove only the sandbox this run created: same name and same id.
    current="$(row | jq -r '.id // empty' 2>/dev/null)" || current=""
    if [[ -z "${id:-}" ]]; then
      say "NOT removing $name: its id was never read; check sbx --cloud ls and remove it by hand"
    elif [[ -z "$current" ]]; then
      say "$name is not listed (already gone, or the listing failed); check sbx --cloud ls"
    elif [[ "$current" != "$id" ]]; then
      say "NOT removing $name: it is now $current, not the $id this run created"
    elif ! "$sbx" --cloud rm --force "$name" >>"$log" 2>&1; then
      say "NOTE could not remove $name; it may still bill: $sbx --cloud rm --force $name"
    fi
  fi
  say "Log: $log"
  if [[ "$failed" == 0 ]]; then say "RESULT: all checks passed"; else say "RESULT: some checks failed"; fi
}

command -v jq >/dev/null || { echo "Install jq first" >&2; exit 2; }
# Never adopt, and so never remove, a sandbox this run did not create.
if ! existing="$(row)"; then echo "sbx --cloud ls failed; is sbx logged in?" >&2; exit 2; fi
if [[ -n "$existing" ]]; then
  echo "A cloud sandbox named $name already exists; remove it or pass another name" >&2
  exit 2
fi
trap cleanup EXIT
record 'sbx version' "$sbx" version

say "=== 1. create $name from $workload with --ttl $ttl --on-timeout stop"
check "create accepts --ttl $ttl --on-timeout stop" \
  "$sbx" --cloud run --detached --name "$name" --ttl "$ttl" --on-timeout stop "$workload" || exit 1
created=1
wait_for 'sandbox running' 900 status_is running
record 'row after create' row
id="$(row | jq -r '.id // empty')"
before="$(expires_at)"
say "id: ${id:-<none>}  expires_at: ${before:-<none>}"
record 'ttl after create' "$sbx" --cloud ttl --json "$name"
check 'write a marker file' "$sbx" --cloud exec "$name" sh -c 'echo survived > /home/agent/probe-marker'
after="$(expires_at)"
record 'ttl after the exec' "$sbx" --cloud ttl --json "$name"
if [[ "$after" == "$before" ]]; then say 'NOTE exec left expires_at alone'
else say "NOTE exec changed expires_at from $before to $after (seen once on 2026-10-22: reset to Docker's 1h default)"; fi
check 'a second exec' "$sbx" --cloud exec "$name" true
record 'ttl after a second exec' "$sbx" --cloud ttl --json "$name"

say "=== 2. wait for the server to expire it"
last="" outcome="" tick=0
expires="$(expires_at)"
limit=$(( $(epoch "$expires") + 600 ))
while (( $(date +%s) < limit )); do
  if ! r="$(row)"; then say 'ls failed, retrying'; sleep 10; continue; fi
  if [[ -z "$r" ]]; then outcome=gone; break; fi
  s="$(printf '%s' "$r" | jq -r '.status')"
  if [[ "$s" != "$last" ]]; then say "status: $s"; last="$s"; fi
  if [[ "$s" == stopped ]]; then outcome=stopped; break; fi
  if (( tick % 6 == 5 )); then
    fresh="$(expires_at)"
    if [[ -n "$fresh" && "$fresh" != "$expires" ]]; then
      say "NOTE expires_at moved from $expires to $fresh"; expires="$fresh"; limit=$(( $(epoch "$expires") + 600 ))
    fi
    say "waiting: status $s, expires_at $expires, $(( $(epoch "$expires") - $(date +%s) ))s to go, giving up at $(date -u -d "@$limit" +%TZ)"
  fi
  tick=$((tick + 1))
  sleep 10
done
case "$outcome" in
  stopped) say 'PASS expiry stopped the sandbox and kept it' ;;
  gone) say 'FAIL expiry removed the sandbox'; failed=1; exit 1 ;;
  *) say "FAIL sandbox still '$last' ten minutes past expires_at"; failed=1; exit 1 ;;
esac
record 'row after expiry' row

say "=== 3. resume by using it"
expect 'marker survives the expiry and a resume' survived "$sbx" --cloud exec "$name" cat /home/agent/probe-marker
wait_for 'sandbox running again' 300 status_is running
record 'ttl after resume' "$sbx" --cloud ttl --json "$name"
after="$(row | jq -r '.id // empty')"
if [[ -n "$id" && "$after" == "$id" ]]; then say 'PASS same sandbox id after resume'; else say "FAIL id changed: $id -> ${after:-<none>}"; failed=1; fi
exit "$failed"
