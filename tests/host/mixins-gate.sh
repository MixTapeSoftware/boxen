#!/usr/bin/env bash
# Task 3 gate (local): do Boxen's mixins compose with the workload and each
# agent, all switched on at once, and do their create-time hooks leave the
# box ready before the agent's first command? Checks the RTK hook lands in
# Claude's settings without losing anything Docker seeded, the workspace and
# Git helper, Tailscale across a restart, and Codex's RTK hooks. Needs sbx,
# Docker and jq. Run from anywhere:
#   bash tests/host/mixins-gate.sh
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/pins.sh"
cd "$(dirname "$0")/../.." || exit 2
gate_begin mixins-gate

SETTINGS=/home/agent/.claude/settings.json
# Everything but RTK's entry, with an emptied hooks object dropped.
WITHOUT_RTK='del(.hooks.PreToolUse) | if .hooks == {} then del(.hooks) else . end'
MIX=v3-mix
in_mix() { sbx exec "$MIX" "$@"; }
settings_of() { sbx exec "$1" sh -c "cat $SETTINGS 2>/dev/null || echo {}" </dev/null | jq -S "$WITHOUT_RTK"; }
socket_up() { sbx exec "$1" test -S /var/run/tailscale/tailscaled.sock; }
REFERENCE="$GATE_DIR/mix-ref.settings.json"
save_reference() { settings_of v3-mix-ref > "$REFERENCE"; }
same_as_reference() { settings_of "$MIX" | cmp -s - "$REFERENCE"; }

say "=== 1. reference: Claude with no Boxen mixin, for what Docker seeds"
create_sandbox v3-mix-ref -- sbx create --name v3-mix-ref --cpus 4 --memory 4g --env BOXEN_AGENT=claude --kit "$(mixin_ref claude)" ./v3/boxen
must 'read the reference settings' save_reference
record 'reference settings' cat "$REFERENCE"
check 'stop v3-mix-ref' sbx stop v3-mix-ref

say "=== 2. Claude with every Boxen mixin: what the install hooks wrote"
create_sandbox "$MIX" -- sbx create --name "$MIX" --cpus 4 --memory 4g \
  --env BOXEN_AGENT=claude --env BOXEN_PLUGINS=tailscale,gh-auth,1pass,rtkplus \
  --kit "$(mixin_ref claude)" --kit ./v3/workspace --kit ./v3/tailscale --kit ./v3/gh-auth \
  --kit ./v3/1pass --kit ./v3/rtkplus-claude ./v3/boxen
# An exec may start the box and its startup hooks, but none of them touch
# these files, so what they show was written at create.
expect 'RTK is the one PreToolUse hook' '["rtk hook claude"]' in_mix jq -c '[.hooks.PreToolUse[].hooks[].command]' "$SETTINGS"
check 'nothing Docker seeded was lost' same_as_reference
record 'composed settings' in_mix cat "$SETTINGS"
expect '/workspace links to the agent-owned workspace' 1000:755 in_mix bash -c 'test -L /workspace && stat -c %u:%a /home/agent/workspace'
expect "Git uses gh's credential helper" '!gh auth git-credential' in_mix git config --global --get credential.https://github.com.helper
expect 'env line added once' 1 in_mix grep -c boxen/env.sh /etc/sandbox-persistent.sh
expect 'no serve preset recorded' '' in_mix cat /etc/boxen/serve-preset

say "=== 3. running"
must "start $MIX" sbx run --detached --name "$MIX"
wait_for 'Tailscale socket' 30 socket_up "$MIX"
check "Boxen's checks pass with every plugin on" in_mix env BOXEN_AGENT=claude BOXEN_PLUGINS=tailscale,gh-auth,1pass,rtkplus bash /usr/local/share/boxen/check.sh
record 'check.sh output' in_mix env BOXEN_AGENT=claude BOXEN_PLUGINS=tailscale,gh-auth,1pass,rtkplus bash /usr/local/share/boxen/check.sh

say "=== 4. restart"
check 'write a marker' in_mix sh -c 'echo marker > /home/agent/workspace/marker'
record 'tailscale state directory' in_mix ls -ld /var/lib/tailscale
before="$(in_mix md5sum /etc/sandbox-persistent.sh </dev/null 2>/dev/null)"
check "stop $MIX" sbx stop "$MIX"
must "start $MIX again" sbx run --detached --name "$MIX"
wait_for 'Tailscale socket after restart' 30 socket_up "$MIX"
expect 'one tailscaled' 1 in_mix pgrep -cx tailscaled
expect 'the marker survived' marker in_mix cat /home/agent/workspace/marker
expect 'env line still once' 1 in_mix grep -c boxen/env.sh /etc/sandbox-persistent.sh
after="$(in_mix md5sum /etc/sandbox-persistent.sh </dev/null 2>/dev/null)"
say "sandbox-persistent.sh across the restart: $([[ "$before" == "$after" ]] && echo unchanged || echo changed)"
check "stop $MIX" sbx stop "$MIX"

say "=== 5. Codex with RTK"
create_sandbox v3-mix-codex -- sbx create --name v3-mix-codex --cpus 4 --memory 4g \
  --env BOXEN_AGENT=codex --env BOXEN_PLUGINS=rtkplus \
  --kit "$(mixin_ref codex)" --kit ./v3/workspace --kit ./v3/rtkplus-codex ./v3/boxen
check "RTK registered Codex's hooks" sbx exec v3-mix-codex test -f /home/agent/.codex/hooks.json
check "nothing written for Claude" sbx exec v3-mix-codex test ! -e "$SETTINGS"
check "Boxen's checks pass for Codex with RTK" sbx exec v3-mix-codex env BOXEN_AGENT=codex BOXEN_PLUGINS=rtkplus bash /usr/local/share/boxen/check.sh
check 'stop v3-mix-codex' sbx stop v3-mix-codex

say "=== 6. Grok with every mixin but RTK"
create_sandbox v3-mix-grok -- sbx create --name v3-mix-grok --cpus 4 --memory 4g \
  --env BOXEN_AGENT=grok --env BOXEN_PLUGINS=tailscale,gh-auth,1pass \
  --kit "$(mixin_ref grok)" --kit ./v3/workspace --kit ./v3/tailscale --kit ./v3/gh-auth --kit ./v3/1pass ./v3/boxen
must 'start v3-mix-grok' sbx run --detached --name v3-mix-grok
wait_for 'Tailscale socket for Grok' 30 socket_up v3-mix-grok
check "Boxen's checks pass for Grok with every other plugin" sbx exec v3-mix-grok env BOXEN_AGENT=grok BOXEN_PLUGINS=tailscale,gh-auth,1pass bash /usr/local/share/boxen/check.sh
check 'stop v3-mix-grok' sbx stop v3-mix-grok
gate_end
