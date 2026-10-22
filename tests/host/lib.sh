# Shared by every host gate (tests/host/*-gate.sh). Each check adds to one
# aggregate result; nothing is claimed from a gate that did not exit 0.
# A gate makes sandboxes only through create_sandbox, which refuses a name
# that already exists (or a listing it cannot read) and records what it
# made; the exit trap removes only those. Needs jq; sbx and docker are
# reached through SBX_BIN and DOCKER_BIN.
SBX="${SBX_BIN:-sbx}"
DOCKER="${DOCKER_BIN:-docker}"
sbx() { command "$SBX" "$@"; }
docker() { command "$DOCKER" "$@"; }
GATE_NAME=""
GATE_LOG=/dev/null
GATE_CHECKS=0
GATE_FAILED=0
GATE_MADE=()

say() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$GATE_LOG"; }
gate_pass() { GATE_CHECKS=$((GATE_CHECKS + 1)); say "PASS $1"; }
gate_fail() { GATE_CHECKS=$((GATE_CHECKS + 1)); GATE_FAILED=$((GATE_FAILED + 1)); say "FAIL $1"; }

gate_begin() {
  GATE_NAME="$1"
  set -uo pipefail
  command -v jq >/dev/null 2>&1 || { echo "Install jq first" >&2; exit 2; }
  GATE_DIR="${BOXEN_VALIDATION_DIR:-local/validation}"
  mkdir -p "$GATE_DIR"
  GATE_DIR="$(cd "$GATE_DIR" && pwd)"
  GATE_LOG="$GATE_DIR/$GATE_NAME.log"
  : > "$GATE_LOG"
  # A registry of its own, so a gate that runs ./boxen never reads or
  # changes the user's.
  BOXEN_STATE_DIR="$GATE_DIR/$GATE_NAME.state"
  rm -rf "$BOXEN_STATE_DIR"
  mkdir -p "$BOXEN_STATE_DIR"
  export BOXEN_STATE_DIR
  trap gate_cleanup EXIT
  trap 'exit 130' INT TERM
  say "=== $GATE_NAME"
  record 'sbx version' sbx version
  record 'docker server' docker version --format '{{.Server.Version}}'
  record 'host' uname -sm
}

# check LABEL CMD...: PASS on exit 0, FAIL otherwise; output goes to the log.
check() {
  local label="$1" tmp status; shift
  tmp="$(mktemp)"
  "$@" >"$tmp" 2>&1 </dev/null; status=$?
  { printf -- '--- %s (exit %s)\n' "$label" "$status"; cat "$tmp"; } >> "$GATE_LOG"
  rm -f "$tmp"
  if [[ "$status" == 0 ]]; then gate_pass "$label"; else gate_fail "$label (exit $status)"; fi
  return "$status"
}
# must LABEL CMD...: like check, but a failure ends the gate here.
must() { check "$@" || gate_abort; }
# expect LABEL EXPECTED CMD...: exit 0 and stdout equal to EXPECTED.
expect() {
  local label="$1" expected="$2" out status; shift 2
  out="$("$@" 2>>"$GATE_LOG" </dev/null)"; status=$?
  { printf -- '--- %s (exit %s)\n' "$label" "$status"; printf '%s\n' "$out"; } >> "$GATE_LOG"
  if [[ "$status" != 0 ]]; then gate_fail "$label (exit $status)"; return 1; fi
  if [[ "$out" == "$expected" ]]; then gate_pass "$label"; else gate_fail "$label (got: ${out:-<nothing>})"; return 1; fi
}
# wait_for LABEL SECONDS CMD...: retry once a second.
wait_for() {
  local label="$1" seconds="$2" i; shift 2
  for ((i = 0; i < seconds; i++)); do
    if "$@" >/dev/null 2>&1 </dev/null; then gate_pass "$label (${i}s)"; return 0; fi
    sleep 1
  done
  gate_fail "$label (not within ${seconds}s)"; return 1
}
# record LABEL CMD...: output to the log and the screen; never fails.
record() { local label="$1"; shift; say "--- $label"; "$@" 2>&1 </dev/null | tee -a "$GATE_LOG"; return 0; }

gate_listing() { if [[ "${1:-local}" == cloud ]]; then sbx --cloud ls --json; else sbx ls --json; fi; }
# claim NAME [cloud]: end the gate unless NAME is free on that backend. A
# listing that fails or cannot be parsed is not a free name.
claim() {
  local name="$1" backend="${2:-local}" listing status
  if ! listing="$(gate_listing "$backend" </dev/null 2>>"$GATE_LOG")"; then
    gate_fail "claim $name (sbx ls failed)"; gate_abort
  fi
  printf '%s' "$listing" | jq -e --arg n "$name" 'any((.sandboxes? // .)[]?; .name == $n)' >/dev/null 2>&1
  status=$?
  case "$status" in
    0) gate_fail "claim $name (exists)"; gate_abort ;;
    1) gate_pass "claim $name" ;;
    *) gate_fail "claim $name (unreadable listing)"; gate_abort ;;
  esac
}
# made NAME [cloud]: this gate created NAME; only these are ever removed.
made() {
  local name="$1" backend="${2:-local}" id=""
  if [[ "$backend" == cloud ]]; then id="$(gate_id "$name")"; fi
  GATE_MADE+=("$backend $name ${id:--}")
  say "made $name ($backend${id:+, $id})"
}
gate_id() {
  sbx --cloud ls --json </dev/null 2>/dev/null |
    jq -r --arg n "$1" '(.sandboxes? // .)[]? | select(.name == $n) | .id // empty' 2>/dev/null
}
# create_sandbox NAME [cloud] -- CMD...: the one way a gate makes a sandbox.
create_sandbox() {
  local name="$1" backend=local
  shift
  if [[ "${1:-}" == cloud ]]; then backend=cloud; shift; fi
  [[ "${1:-}" == -- ]] && shift
  claim "$name" "$backend"
  must "create $name" "$@"
  made "$name" "$backend"
}

gate_abort() { say "Stopping: later steps depend on that one."; gate_end; }
gate_end() {
  say "$GATE_CHECKS checks, $GATE_FAILED failed (log: $GATE_LOG)"
  exit $((GATE_FAILED > 0))
}
gate_cleanup() {
  local entry backend name id current
  if declare -F cleanup >/dev/null; then cleanup </dev/null || true; fi
  for entry in "${GATE_MADE[@]+"${GATE_MADE[@]}"}"; do
    read -r backend name id <<< "$entry"
    if [[ "$backend" == cloud ]]; then
      if [[ "$id" != - ]]; then
        current="$(gate_id "$name")"
        if [[ -n "$current" && "$current" != "$id" ]]; then
          say "NOT removing $name: its id is now $current, not the $id this gate made"; continue
        fi
      fi
      sbx --cloud rm --force "$name" </dev/null >>"$GATE_LOG" 2>&1 || say "NOTE could not remove $name; remove it with sbx --cloud rm"
    else
      sbx rm --force "$name" </dev/null >>"$GATE_LOG" 2>&1 || say "NOTE could not remove $name; remove it with sbx rm"
    fi
  done
}
