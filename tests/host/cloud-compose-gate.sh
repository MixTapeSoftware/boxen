#!/usr/bin/env bash
# Task 1 gate (cloud): does Boxen's workload with Docker's Claude mixin come
# up in the cloud, keep Docker's sudo, survive a stop and a real expiry with
# its files and id, and forward a port over SSH? Task 6
# does not start until this passes. Needs sbx (logged in, cloud plan), jq,
# ssh, curl and GNU date; about fifteen minutes of cloud compute.
#   BOXEN_CLOUD_POLICY_NOTE='account default: allow all' bash tests/host/cloud-compose-gate.sh
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/pins.sh"
cd "$(dirname "$0")/../.." || exit 2
gate_begin cloud-compose-gate
for tool in ssh curl; do command -v "$tool" >/dev/null || { say "Install $tool first"; exit 2; }; done
# The expiry wait parses timestamps with GNU date; check before spending compute.
date -u -d 2026-01-01T00:00:00Z +%s >/dev/null 2>&1 || { say "Needs GNU date (date -d); on macOS install coreutils and put gdate first as date"; exit 2; }

NAME=v3-cloud-core
SOCK="${TMPDIR:-/tmp}/bxg-$$.sock"
ID=""
cleanup() { [[ ! -S "$SOCK" ]] || ssh -S "$SOCK" -O exit "$ID@sbx_cloud" >/dev/null 2>&1; }
row() { sbx --cloud ls --json | jq -c --arg n "$NAME" '.sandboxes[] | select(.name == $n)'; }
status_is() { [[ "$(row | jq -r .status)" == "$1" ]]; }
expires_at() { sbx --cloud ttl --json "$NAME" | jq -r '.expires_at // empty'; }
epoch() { date -u -d "$1" +%s; }

say "=== 1. account"
must 'BOXEN_CLOUD_POLICY_NOTE describes the account network policy' test -n "${BOXEN_CLOUD_POLICY_NOTE:-}"
say "policy note: ${BOXEN_CLOUD_POLICY_NOTE:-}"

say "=== 2. create, composed"
create_sandbox "$NAME" cloud -- sbx --cloud run --detached --name "$NAME" --ttl 5m --on-timeout stop \
  --env BOXEN_CLOUD=1 --env BOXEN_AGENT=claude --kit "$(mixin_ref claude)" ./v3/boxen
check 'cloud box keeps sudo' sbx --cloud exec "$NAME" sudo -n true
check 'claude runs from a login shell' sbx --cloud exec "$NAME" bash -lc 'claude --version'
if [[ -d v3/workspace ]]; then
  expect 'workspace link' linked sbx --cloud exec "$NAME" sh -c 'test -L /workspace && echo linked'
fi

say "=== 3. running, with the composition and hooks"
wait_for 'running after create' 600 status_is running || gate_abort
ID="$(row | jq -r '.id // .sandbox_id // empty')"
must 'sandbox id listed' test -n "$ID"
say "sandbox id: $ID"
record 'ttl after create' sbx --cloud ttl --json "$NAME"
record 'staged kits, env line, Claude settings' sbx --cloud exec "$NAME" sh -c \
  'ls /usr/share/sandbox/kit/; grep -c boxen/env.sh /etc/sandbox-persistent.sh; cat /home/agent/.claude/settings.json'

say "=== 4. stop and resume"
must 'write a marker' sbx --cloud exec "$NAME" sh -c 'echo marker > /home/agent/marker'
must 'stop' sbx --cloud stop "$NAME"
wait_for 'stopped after stop' 120 status_is stopped
expect 'marker after a resume' marker sbx --cloud exec "$NAME" cat /home/agent/marker
wait_for 'running after resume' 300 status_is running
record 'ttl after resume' sbx --cloud ttl --json "$NAME"

say "=== 5. SSH forwarding"
check 'sbx --cloud setup ssh' sbx --cloud setup ssh
record 'ssh proxy config' sh -c 'ssh -G sbx_cloud | grep -i proxycommand'
check 'web server in the sandbox' sbx --cloud exec "$NAME" sh -c \
  'cd /tmp && (setsid nohup python3 -m http.server 8000 >/dev/null 2>&1 </dev/null &); sleep 2'
# A file redirect, not a capture: ssh -f keeps its stdout open after it forks.
check 'ssh master with a local forward' ssh -f -N -M -S "$SOCK" -o ExitOnForwardFailure=yes \
  -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 \
  -L 127.0.0.1:18000:127.0.0.1:8000 "$ID@sbx_cloud"
expect 'request through the tunnel' 200 curl -sS --max-time 10 -o /dev/null -w '%{http_code}' http://127.0.0.1:18000/
check 'master answers' ssh -S "$SOCK" -O check "$ID@sbx_cloud"
record 'ssh login user' ssh -S "$SOCK" "$ID@sbx_cloud" id
ssh -S "$SOCK" -O exit "$ID@sbx_cloud" >/dev/null 2>&1

say "=== 6. a real expiry"
# Wait on the deadline the server holds, not the one asked for: an exec
# has once reset a five-minute TTL to Docker's one-hour default.
expires="$(expires_at)"
started="$(date +%s)"
limit=$(( $(epoch "$expires") + 600 ))
(( limit <= started + 4500 )) || limit=$((started + 4500))
say "expires_at $expires; giving up at $(date -u -d "@$limit" +%TZ)"
outcome="" last="" tick=0
while (( $(date +%s) < limit )); do
  if ! r="$(row)"; then say 'ls failed, retrying'; sleep 10; continue; fi
  if [[ -z "$r" ]]; then outcome=gone; break; fi
  s="$(printf '%s' "$r" | jq -r .status)"
  if [[ "$s" != "$last" ]]; then say "status: $s"; last="$s"; fi
  if [[ "$s" == stopped ]]; then outcome=stopped; break; fi
  if (( tick % 6 == 5 )); then
    fresh="$(expires_at)"
    if [[ -n "$fresh" && "$fresh" != "$expires" ]]; then
      say "NOTE expires_at moved from $expires to $fresh"; expires="$fresh"
      limit=$(( $(epoch "$expires") + 600 )); (( limit <= started + 4500 )) || limit=$((started + 4500))
    fi
  fi
  tick=$((tick + 1)); sleep 10
done
case "$outcome" in
  stopped) gate_pass 'expiry stopped the sandbox and kept it' ;;
  gone) gate_fail 'expiry removed the sandbox'; gate_abort ;;
  *) gate_fail "still '$last' ten minutes past expires_at"; gate_abort ;;
esac
expect 'marker after the expiry and a resume' marker sbx --cloud exec "$NAME" cat /home/agent/marker
wait_for 'running after the second resume' 300 status_is running
expect 'same sandbox id' "$ID" sh -c '"$0" --cloud ls --json | jq -r --arg n "$1" ".sandboxes[] | select(.name == \$n) | .id"' "$SBX" "$NAME"
record 'ttl after the second resume' sbx --cloud ttl --json "$NAME"
gate_end
