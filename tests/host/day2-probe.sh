#!/usr/bin/env bash
# What does Docker do to a stopped cloud sandbox after its 24-hour cap?
# Two phases, a day apart. The result file is an input to the acceptance
# gate: the README's retention claim is written from it.
#
#   bash tests/host/day2-probe.sh start   # create a box with --on-timeout stop, write a marker, record it
#   bash tests/host/day2-probe.sh check   # 24 h later: still listed? does a resume work? then remove it
#
# Needs sbx (logged in, cloud plan), jq and GNU date. Never touches a
# sandbox it did not create. Writes local/validation/day2-probe.json (start)
# and local/validation/day2-probe.result (check): one of
#   kept        listed and resumed with the marker intact
#   unresumable listed but a resume failed
#   gone        no longer listed
set -uo pipefail
phase="${1:-}"
name="${BOXEN_PROBE_NAME:-day2-probe}"
workload="${BOXEN_PROBE_WORKLOAD:-docker.io/docker/sbx-kit-claude:2.1.267}"
sbx="${SBX_BIN:-sbx}"
project="$(cd "$(dirname "$0")/../.." && pwd)"
dir="${BOXEN_VALIDATION_DIR:-$project/local/validation}"
mkdir -p "$dir"
state="$dir/day2-probe.json"
result="$dir/day2-probe.result"
log="$dir/day2-probe-$(date -u +%Y%m%d-%H%M%S).log"

now() { date -u +%FT%TZ; }
say() { printf '%s %s\n' "$(now)" "$*" | tee -a "$log"; }
record() { local label="$1"; shift; say "--- $label"; "$@" 2>&1 | tee -a "$log"; }
# row: this sandbox's ls --json row, or nothing. Fails only if ls failed.
row() {
  local out
  out="$("$sbx" --cloud ls --json)" || return 1
  printf '%s' "$out" | jq -c --arg n "$name" '.sandboxes[] | select(.name == $n)'
}
command -v jq >/dev/null || { echo "Install jq first" >&2; exit 2; }

case "$phase" in
  start)
    [[ ! -s "$state" ]] || { echo "$state already records a box; run 'check' first" >&2; exit 2; }
    if ! existing="$(row)"; then echo "sbx --cloud ls failed; is sbx logged in?" >&2; exit 2; fi
    [[ -z "$existing" ]] || { echo "A cloud sandbox named $name already exists; remove it or set BOXEN_PROBE_NAME" >&2; exit 2; }
    record 'sbx version' "$sbx" version
    say "create $name from $workload with --ttl 5m --on-timeout stop"
    "$sbx" --cloud run --detached --name "$name" --ttl 5m --on-timeout stop "$workload" 2>&1 | tee -a "$log"
    [[ "${PIPESTATUS[0]}" == 0 ]] || { say "FAIL create"; exit 1; }
    "$sbx" --cloud exec "$name" sh -c 'echo survived > /home/agent/probe-marker' 2>&1 | tee -a "$log"
    r="$(row)" || r=""
    if [[ -z "$r" ]] || [[ -z "$(printf '%s' "$r" | jq -r '.id // empty')" ]]; then
      say "FAIL $name was created but is not listed with an id; nothing recorded. Check sbx --cloud ls and remove it by hand."
      exit 1
    fi
    printf '%s' "$r" | jq --arg started "$(now)" '{name, id, created_at, started_by_probe: $started}' > "$state"
    record 'recorded' cat "$state"
    record 'ttl' "$sbx" --cloud ttl --json "$name"
    say "Leave it alone. It stops at its expiry and bills no compute while stopped."
    say "After $(date -u -d "$(jq -r .created_at "$state" | cut -c1-19)Z + 24 hours + 15 minutes" +%FT%TZ) run: bash tests/host/day2-probe.sh check"
    ;;
  check)
    [[ -s "$state" ]] || { echo "No $state; run 'start' first" >&2; exit 2; }
    id="$(jq -r .id "$state")"; created="$(jq -r .created_at "$state" | cut -c1-19)Z"
    age=$(( $(date +%s) - $(date -u -d "$created" +%s) ))
    if (( age < 24 * 3600 )); then
      say "Too early: $name is $((age / 3600)) h $(( (age % 3600) / 60 )) min old; the cap is at 24 h. Nothing done."
      exit 2
    fi
    say "checking $name ($id, created $created, age $((age / 3600)) h)"
    if ! r="$(row)"; then say "FAIL sbx --cloud ls failed; nothing recorded"; exit 1; fi
    outcome=""
    if [[ -z "$r" ]]; then
      outcome=gone
      say "gone: $name is no longer listed"
    else
      record 'row' printf '%s\n' "$r"
      listed="$(printf '%s' "$r" | jq -r '.id // empty')"
      if [[ "$listed" != "$id" ]]; then
        say "FAIL the sandbox named $name is ${listed:-<no id>}, not the $id this probe created; nothing touched, nothing recorded"
        exit 1
      fi
      record 'ttl before resume' "$sbx" --cloud ttl --json "$name"
      marker="$("$sbx" --cloud exec "$name" cat /home/agent/probe-marker 2>>"$log")"
      if [[ "$marker" == survived ]]; then outcome=kept; say "kept: resumed after $((age / 3600)) h with the marker intact"
      else outcome=unresumable; say "unresumable: listed, but the resume failed or the marker is missing (got: ${marker:-<nothing>})"; fi
      record 'ttl after resume' "$sbx" --cloud ttl --json "$name"
      "$sbx" --cloud rm --force "$name" >/dev/null 2>&1 || say "NOTE rm --force $name failed; remove it by hand"
    fi
    printf '%s\t%s\t%s\t%s\n' "$outcome" "$id" "$created" "$(now)" > "$result"
    say "RESULT: $outcome (recorded in $result)"
    rm -f "$state"
    ;;
  *) echo "Use: $0 start | check" >&2; exit 2 ;;
esac
