#!/usr/bin/env bash
# Answers two questions before any v3 work, using Docker's pinned Claude
# workload alone (no Boxen kits), so the result is about the cloud, not us:
#   1. Can a Claude cloud sandbox be created with --on-timeout stop, then
#      stopped and resumed with its files intact?
#   2. Does Docker's SSH relay allow local port forwarding?
# Needs: sbx (logged in, cloud plan), jq, ssh, curl. Costs a few minutes of
# cloud compute. Logs to local/validation/. Exits 1 if any check failed.
#
#   bash tests/host/cloud-probe.sh            # create, test, remove
#   BOXEN_PROBE_KEEP=1 bash tests/host/cloud-probe.sh   # leave it for the expiry check
set -uo pipefail
name="${1:-v3-probe}"
workload="${BOXEN_PROBE_WORKLOAD:-docker.io/docker/sbx-kit-claude:2.1.267}"
sbx="${SBX_BIN:-sbx}"
project="$(cd "$(dirname "$0")/../.." && pwd)"
dir="${BOXEN_VALIDATION_DIR:-$project/local/validation}"
mkdir -p "$dir"
log="$dir/cloud-probe-$(date +%Y%m%d-%H%M%S).log"
sock="${TMPDIR:-/tmp}/boxen-probe-$$.sock"
failed=0
id=""
created=0

say() { printf '%s\n' "$*" | tee -a "$log"; }
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
status_is() { "$sbx" --cloud ls --json | jq -e --arg n "$name" --arg s "$1" '.sandboxes[] | select(.name == $n) | .status == $s'; }
cleanup() {
  [[ -S "$sock" ]] && ssh -S "$sock" -O exit "$id@sbx_cloud" >/dev/null 2>&1
  if [[ "$created" != 1 ]]; then
    say "Nothing to remove: $name was not created by this run."
  elif [[ "${BOXEN_PROBE_KEEP:-0}" == 1 ]]; then
    say "Kept $name for the expiry check. In about 65 minutes run:"
    say "  $sbx --cloud ls            # expect $name stopped, not gone"
    say "  $sbx --cloud exec $name cat /home/agent/probe-marker   # expect: marker"
    say "  $sbx --cloud rm --force $name"
  else
    "$sbx" --cloud rm --force "$name" >/dev/null 2>&1 || true
  fi
  say "Log: $log"
  if [[ "$failed" == 0 ]]; then say "RESULT: all checks passed"; else say "RESULT: some checks failed"; fi
}
for tool in jq ssh curl; do command -v "$tool" >/dev/null || { echo "Install $tool first" >&2; exit 2; }; done
# Never adopt, and so never remove, a sandbox this run did not create; a
# listing that fails is not the same as the name being free.
if ! listing="$("$sbx" --cloud ls --json)"; then echo "sbx --cloud ls failed; is sbx logged in?" >&2; exit 2; fi
if printf '%s' "$listing" | jq -e --arg n "$name" 'any(.sandboxes[]; .name == $n)' >/dev/null; then
  echo "A cloud sandbox named $name already exists; remove it or pass another name" >&2; exit 2
fi
trap cleanup EXIT
record 'sbx version' "$sbx" version
record 'host' uname -sm

# 1. Create with a stop-at-expiry policy. The full output matters: a
#    "volume@1" fallback or template-bake message is what we want recorded.
say "=== 1. create $name from $workload with --ttl 1h --on-timeout stop"
check 'create accepts --on-timeout stop' \
  "$sbx" --cloud run --detached --name "$name" --ttl 1h --on-timeout stop "$workload" || exit 1
created=1
wait_for 'sandbox running' 900 status_is running
record 'sandbox row' sh -c "$sbx --cloud ls --json | jq -c --arg n '$name' '.sandboxes[] | select(.name == \$n)'"
id="$("$sbx" --cloud ls --json | jq -r --arg n "$name" '.sandboxes[] | select(.name == $n) | .id // .sandbox_id // empty')"
say "sandbox id: ${id:-<not found in ls --json; see the row above>}"
record 'ttl after create' "$sbx" --cloud ttl --json "$name"
check 'write a marker file' "$sbx" --cloud exec "$name" sh -c 'echo marker > /home/agent/probe-marker'
record 'who exec runs as' "$sbx" --cloud exec "$name" id
record 'ttl after two execs (2026-10-22: an early exec once reset a TTL to 1h)' "$sbx" --cloud ttl --json "$name"

# 2. SSH port forwarding through Docker's relay.
say "=== 2. SSH forwarding"
check 'sbx --cloud setup ssh' "$sbx" --cloud setup ssh
record 'ssh config for sbx_cloud' sh -c 'ssh -G sbx_cloud | grep -i -E "^(proxycommand|hostname|user) "'
if [[ -n "$id" ]]; then
  check 'web server inside the sandbox' "$sbx" --cloud exec "$name" sh -c \
    'cd /tmp && (setsid nohup python3 -m http.server 8000 >/tmp/http.log 2>&1 </dev/null &); sleep 2; curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8000/ | grep -q 200'
  # Not through check: ssh -f keeps the inherited stdout open after it
  # backgrounds, so capturing its output would wait forever.
  if ssh -f -N -M -S "$sock" \
       -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 \
       -L 127.0.0.1:18000:127.0.0.1:8000 "$id@sbx_cloud" </dev/null >>"$log" 2>&1; then
    say 'PASS ssh master with a local forward'
  else
    say "FAIL ssh master with a local forward (exit $?)"; failed=1
  fi
  expect 'request through the tunnel' 200 curl -sS --max-time 15 -o /dev/null -w '%{http_code}' http://127.0.0.1:18000/
  expect 'listener bound to 127.0.0.1 only' 127.0.0.1:18000 sh -c "ss -ltn 2>/dev/null | awk '\$4 ~ /:18000\$/ {print \$4}' | head -1"
  record 'ssh login user' ssh -S "$sock" "$id@sbx_cloud" id
  ssh -S "$sock" -O exit "$id@sbx_cloud" >/dev/null 2>&1
else
  say "FAIL ssh checks skipped: no sandbox id"; failed=1
fi

# 1, continued. Stop, confirm it stopped, resume by using it, confirm the file.
say "=== 1. stop and resume"
check 'stop' "$sbx" --cloud stop "$name"
wait_for 'sandbox stopped' 180 status_is stopped
expect 'marker survives a resume' marker "$sbx" --cloud exec "$name" cat /home/agent/probe-marker
wait_for 'sandbox running again' 300 status_is running
record 'ttl after resume' "$sbx" --cloud ttl --json "$name"
expect 'same sandbox id after resume' "$id" sh -c "$sbx --cloud ls --json | jq -r --arg n '$name' '.sandboxes[] | select(.name == \$n) | .id // .sandbox_id // empty'"
exit "$failed"
