#!/usr/bin/env bash
# Task 5 gate: does the launcher itself create, check, open and validate from
# the v3 kits? Runs ./bxn against real sbx and Docker with a registry of its
# own (gate_begin), so the user's is never read or changed. BOXEN_OLD_SANDBOX
# may name a sandbox the v2 launcher made, which sbx ls must list, to show that
# the guest-script probe still reaches its scripts; unset, that part records
# SKIP. Needs sbx, Docker with buildx, and jq. Run from anywhere:
#   bash tests/host/launcher-gate.sh
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/../.." || exit 2
gate_begin launcher-gate

say "=== 1. host"
check './bxn doctor' ./bxn doctor

say "=== 2. v3-e2e: Claude with tailscale, gh-auth and RTK, through the launcher"
create_sandbox v3-e2e -- ./bxn create v3-e2e --no-copy --agent claude --plugins tailscale,gh-auth,rtkplus --no-tui
check './bxn check v3-e2e' ./bxn check v3-e2e
expect 'mise shims on PATH once in a login shell' 1 ./bxn shell v3-e2e 'echo $PATH | tr : "\n" | grep -c mise/shims'
expect '--with-sudo grants sudo for the session' sudo-ok ./bxn shell --with-sudo v3-e2e 'sudo -n true && echo sudo-ok'
check 'no standing sudo otherwise' ./bxn exec v3-e2e bash -c '! sudo -n true'
check 'RTK hook in Claude settings' ./bxn exec v3-e2e grep -q 'rtk hook claude' /home/agent/.claude/settings.json
check 'stop v3-e2e' ./bxn stop v3-e2e

say "=== 3. ./bxn validate"
check './bxn validate' ./bxn validate

say "=== 4. v3-open: a shell box with --open-network"
create_sandbox v3-open -- ./bxn create v3-open --no-copy --plugins none --no-tui --open-network
expect 'example.com answers through the open network' 200 ./bxn exec v3-open sh -c 'curl -sS --max-time 15 -o /dev/null -w "%{http_code}" https://example.com/'
check 'stop v3-open' ./bxn stop v3-open

say "=== 5. v3-serve: supabase-serve reaches the tailscale mixin's install hook"
create_sandbox v3-serve -- ./bxn create v3-serve --no-copy --plugins supabase-serve --no-tui
expect 'serve preset recorded' supabase ./bxn exec v3-serve cat /etc/boxen/serve-preset
check 'stop v3-serve' ./bxn stop v3-serve

say "=== 6. a sandbox the v2 launcher made"
# Not this gate's sandbox: borrow ends the gate unless sbx ls lists it, and
# starts it only when it is stopped; leave it as found.
if [[ -n "${BOXEN_OLD_SANDBOX:-}" ]]; then
  borrow "$BOXEN_OLD_SANDBOX"
  check "./bxn check $BOXEN_OLD_SANDBOX" ./bxn check "$BOXEN_OLD_SANDBOX"
  expect "./bxn $BOXEN_OLD_SANDBOX runs a command" old-ok ./bxn "$BOXEN_OLD_SANDBOX" 'echo old-ok'
  if [[ "$GATE_BORROWED" == 1 ]]; then check "stop $BOXEN_OLD_SANDBOX again" ./bxn stop "$BOXEN_OLD_SANDBOX"; fi
else
  say 'SKIP old sandbox: set BOXEN_OLD_SANDBOX to a sandbox the v2 launcher made'
fi
gate_end
