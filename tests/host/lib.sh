# Shared by every host gate (tests/host/*-gate.sh). Each check adds to one
# aggregate result; nothing is claimed from a gate that did not exit 0.
# A gate makes sandboxes only through create_sandbox, which refuses a name
# that already exists (or a listing it cannot read) and records what it
# made; the exit trap removes only those. A sandbox it did not make is used
# only through borrow, which never makes one. Needs jq; sbx and docker are
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
GATE_BORROWED=0

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
  # A registry of its own, so a gate that runs ./bxn never reads or
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

gate_listing() { sbx ls --json; }
# claim NAME: end the gate unless NAME is free. A listing that fails or
# cannot be parsed is not a free name.
claim() {
  local name="$1" listing status
  if ! listing="$(gate_listing </dev/null 2>>"$GATE_LOG")"; then
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
# borrow NAME: use NAME, a local sandbox this gate did not make. End the gate
# unless the listing shows it: sbx run --name with a name that is not listed
# would make one, and a listing that fails or cannot be parsed is not proof
# that NAME exists. A running sandbox is used as it is; a stopped one is
# started, with GATE_BORROWED=1 so the gate can stop it again and leave it
# as found. Any other status, or none, ends the gate, as does a failed start
# (a later sbx exec would start it without recording that).
borrow() {
  local name="$1" listing status
  GATE_BORROWED=0
  if ! listing="$(gate_listing </dev/null 2>>"$GATE_LOG")"; then
    gate_fail "borrow $name (sbx ls failed)"; gate_abort
  fi
  printf '%s' "$listing" | jq -e --arg n "$name" 'any((.sandboxes? // .)[]?; .name == $n)' >/dev/null 2>&1
  status=$?
  case "$status" in
    0) ;;
    1) gate_fail "borrow $name (not listed by sbx ls; sbx run would make it)"; gate_abort ;;
    *) gate_fail "borrow $name (unreadable listing)"; gate_abort ;;
  esac
  status="$(printf '%s' "$listing" | jq -r --arg n "$name" '[(.sandboxes? // .)[]? | select(.name == $n) | .status][0] // ""')"
  case "$status" in
    running) ;;
    stopped)
      check "start $name" sbx run -d --name "$name" || gate_abort
      GATE_BORROWED=1 ;;
    *) gate_fail "borrow $name (status ${status:-<none>}; only running or stopped is left as found)"; gate_abort ;;
  esac
}
# made NAME: this gate created NAME; only these are ever removed.
made() {
  GATE_MADE+=("$1")
  say "made $1"
}
# gate_listed_now NAME: true when sbx now lists NAME.
gate_listed_now() {
  gate_listing </dev/null 2>/dev/null |
    jq -e --arg n "$1" 'any((.sandboxes? // .)[]?; .name == $n)' >/dev/null 2>&1
}
# create_sandbox NAME -- CMD...: the one way a gate makes a sandbox.
create_sandbox() {
  local name="$1"
  shift
  [[ "${1:-}" == -- ]] && shift
  claim "$name"
  if ! check "create $name" "$@"; then
    # The name was free a moment ago, so a sandbox there now is this
    # attempt's partial create: record it so cleanup removes it.
    if gate_listed_now "$name"; then made "$name"; fi
    gate_abort
  fi
  made "$name"
}

gate_abort() { say "Stopping: later steps depend on that one."; gate_end; }
gate_end() {
  say "$GATE_CHECKS checks, $GATE_FAILED failed (log: $GATE_LOG)"
  exit $((GATE_FAILED > 0))
}
gate_cleanup() {
  local name
  if declare -F cleanup >/dev/null; then cleanup </dev/null || true; fi
  for name in "${GATE_MADE[@]+"${GATE_MADE[@]}"}"; do
    sbx rm --force "$name" </dev/null >>"$GATE_LOG" 2>&1 || say "NOTE could not remove $name; remove it with sbx rm"
  done
}
