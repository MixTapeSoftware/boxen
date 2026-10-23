#!/usr/bin/env bash
# Task 6 gate: does a real expiry stop, and keep, the sandboxes the launcher
# makes in the cloud: Claude with RTK, and a shell box? Both are created with
# BOXEN_CLOUD_TTL=5m and watched until they stop, on the deadline the server
# reports (an early exec has reset a five-minute TTL to Docker's one-hour
# default), then resumed through ./boxen with their files and ids. About ten
# minutes, at most 75. Needs sbx (logged in, cloud plan), Docker with buildx,
# jq and GNU date. Run from anywhere:
#   bash tests/host/expiry-gate.sh
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/../.." || exit 2
gate_begin expiry-gate
date -u -d 2026-01-01T00:00:00Z +%s >/dev/null 2>&1 || { say "Needs GNU date (date -d); on macOS install coreutils and put gdate first as date"; exit 2; }

NAMES=(v3-expiry v3-expiry-shell)
row() { sbx --cloud ls --json | jq -c --arg n "$1" '.sandboxes[] | select(.name == $n)'; }
id_of() { row "$1" | jq -r '.id // .sandbox_id // empty'; }
expires_at() { sbx --cloud ttl --json "$1" | jq -r '.expires_at // empty'; }
epoch() { date -u -d "$1" +%s; }

say "=== 1. create both with BOXEN_CLOUD_TTL=5m"
create_sandbox v3-expiry cloud -- env BOXEN_CLOUD_TTL=5m ./boxen create v3-expiry --no-copy --cloud --agent claude --plugins rtkplus --no-tui
create_sandbox v3-expiry-shell cloud -- env BOXEN_CLOUD_TTL=5m ./boxen create v3-expiry-shell --no-copy --cloud --plugins none --no-tui
ids=() expires=() limits=() outcomes=() last=()
started="$(date +%s)"
for i in 0 1; do
  n="${NAMES[i]}"
  check "marker in $n" ./boxen exec "$n" sh -c 'echo survived > /workspace/marker'
  ids[i]="$(id_of "$n")"
  # Two empty ids would make the later comparison pass without reading one.
  must "$n id listed" test -n "${ids[i]}"
  record "$n id" printf '%s\n' "${ids[i]}"
  record "$n ttl" sbx --cloud ttl --json "$n"
  expires[i]="$(expires_at "$n")"
  limits[i]=$(( $(epoch "${expires[i]}") + 600 ))
  (( limits[i] <= started + 4500 )) || limits[i]=$((started + 4500))
  outcomes[i]="" last[i]=""
done

say "=== 2. watch both until they stop"
tick=0
while [[ -z "${outcomes[0]}" || -z "${outcomes[1]}" ]]; do
  now="$(date +%s)"
  for i in 0 1; do
    n="${NAMES[i]}"
    [[ -z "${outcomes[i]}" ]] || continue
    if (( now >= limits[i] )); then outcomes[i]=late; continue; fi
    if ! r="$(row "$n")"; then say "ls failed for $n, retrying"; continue; fi
    if [[ -z "$r" ]]; then outcomes[i]=gone; continue; fi
    s="$(printf '%s' "$r" | jq -r .status)"
    if [[ "$s" != "${last[i]}" ]]; then say "$n status: $s"; last[i]="$s"; fi
    if [[ "$s" == stopped ]]; then outcomes[i]=stopped; continue; fi
    # Re-read the deadline once a minute: it is the server's, not ours.
    if (( tick % 6 == 5 )); then
      fresh="$(expires_at "$n")"
      if [[ -n "$fresh" && "$fresh" != "${expires[i]}" ]]; then
        say "NOTE $n expires_at moved from ${expires[i]} to $fresh"; expires[i]="$fresh"
        limits[i]=$(( $(epoch "$fresh") + 600 )); (( limits[i] <= started + 4500 )) || limits[i]=$((started + 4500))
      fi
    fi
  done
  tick=$((tick + 1))
  [[ -n "${outcomes[0]}" && -n "${outcomes[1]}" ]] || sleep 10
done

say "=== 3. outcomes and the resume"
for i in 0 1; do
  n="${NAMES[i]}"
  case "${outcomes[i]}" in
    stopped) gate_pass "expiry stopped $n and kept it" ;;
    gone) gate_fail "expiry removed $n"; continue ;;
    *) gate_fail "$n still '${last[i]}' ten minutes past expires_at ${expires[i]}"; continue ;;
  esac
  expect "$n marker after the expiry, through ./boxen (which resumes it)" survived ./boxen exec "$n" cat /workspace/marker
  expect "$n keeps its id" "${ids[i]}" id_of "$n"
  record "$n ttl after the resume (a fresh period)" sbx --cloud ttl --json "$n"
done
gate_end
