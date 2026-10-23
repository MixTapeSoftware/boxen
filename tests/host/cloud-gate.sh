#!/usr/bin/env bash
# Task 6 gate: boxen create --cloud end to end, through the launcher: a copied
# workspace and a GitHub token on stdin, the TTL it reads back, egress, an SSH
# tunnel to 127.0.0.1, Docker inside, a stop and resume with its files and id,
# Codex and Grok, and root work through Docker's sudo. Needs sbx (logged in,
# cloud plan), Docker with buildx, jq, ssh, curl, and:
#   GH_TEST_TOKEN            a fine-grained token made for this run; revoke it after
#   BOXEN_TEST_PRIVATE_REPO  owner/name of a private repository it can read
#   BOXEN_CLOUD_POLICY_NOTE  the account's network default, for the egress log
#   BOXEN_TEST_TS_KEY        optional: a tagged, ephemeral Tailscale auth key
# The token and key travel on stdin only. Run from anywhere:
#   bash tests/host/cloud-gate.sh
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/../.." || exit 2
gate_begin cloud-gate
for tool in ssh curl; do command -v "$tool" >/dev/null || { say "Install $tool first"; exit 2; }; done

EGRESS_LOG="$GATE_DIR/cloud-gate-egress.log"
fixture=""
# The library removes the sandboxes; close their tunnels first.
cleanup() {
  local n
  for n in v3-cloud v3-cloud-ts; do
    if [[ -s "$BOXEN_STATE_DIR/tunnels/$n.id" ]]; then ./boxen stop "$n" >/dev/null 2>&1 || true; fi
  done
  if [[ -n "$fixture" ]]; then rm -rf "$fixture"; fi
}
row() { sbx --cloud ls --json | jq -c --arg n "$1" '.sandboxes[] | select(.name == $n)'; }
status_is() { [[ "$(row "$1" | jq -r .status)" == "$2" ]]; }
id_of() { row "$1" | jq -r '.id // .sandbox_id // empty'; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
listeners() {
  if command -v ss >/dev/null; then ss -ltnH "sport = :$1" | awk '{ print $4 }'
  else lsof -nP -iTCP:"$1" -sTCP:LISTEN | awk 'NR > 1 { print $9 }'; fi | sort -u
}

say "=== 0. inputs"
must 'GH_TEST_TOKEN is set' test -n "${GH_TEST_TOKEN:-}"
must 'BOXEN_TEST_PRIVATE_REPO is set' test -n "${BOXEN_TEST_PRIVATE_REPO:-}"
must 'BOXEN_CLOUD_POLICY_NOTE describes the account network policy' test -n "${BOXEN_CLOUD_POLICY_NOTE:-}"
say "policy note: $BOXEN_CLOUD_POLICY_NOTE"
export GH_TEST_TOKEN

say "=== 1. fixture"
fixture="$(mktemp -d)"
printf 'preserved\n' > "$fixture/.hidden"
head -c 1048576 /dev/urandom > "$fixture/blob"
digest="$(sha "$fixture/blob")"
record 'blob digest' printf '%s\n' "$digest"

say "=== 2. Claude in the cloud: a copied workspace, the token on stdin, RTK"
started="$(date +%s)"
create_sandbox v3-cloud cloud -- sh -c 'printf "%s\n" "$GH_TEST_TOKEN" |
  ./boxen create v3-cloud "$1" --cloud --agent claude --gh-token-stdin --plugins rtkplus --no-tui --ack-env' sh "$fixture"
upload=$(( $(date +%s) - started ))
check 'GitHub secret stored for v3-cloud' sh -c '"$0" --cloud secret ls --sandbox v3-cloud | grep -q github' "$SBX"
record 'ttl after create' sbx --cloud ttl --json v3-cloud
# Never shorter than asked, less ten minutes of create-time steps; a longer
# period is the launcher's to report in its Stops at line, in the log above.
check 'TTL not short' sh -c 'test "$("$0" --cloud ttl --json v3-cloud | jq .expires_in_seconds)" -ge 28200' "$SBX"
check './boxen check v3-cloud' ./boxen check v3-cloud
expect 'blob copied byte for byte' "$digest" ./boxen exec v3-cloud sh -c 'sha256sum /workspace/blob | cut -d" " -f1'
expect '.hidden copied' preserved ./boxen exec v3-cloud cat /workspace/.hidden
check 'private repository through the stored token' ./boxen exec v3-cloud git ls-remote "https://github.com/$BOXEN_TEST_PRIVATE_REPO" HEAD
# The post-create path: does a secret set now apply at once, or at the next start?
if printf '%s' "$GH_TEST_TOKEN" | ./boxen auth github v3-cloud >>"$GATE_LOG" 2>&1; then
  gate_pass 'boxen auth github after create'
  if ./boxen exec v3-cloud git ls-remote "https://github.com/$BOXEN_TEST_PRIVATE_REPO" HEAD </dev/null >>"$GATE_LOG" 2>&1; then
    say 'secret set after create: live'
  else
    check 'stop to apply the new secret' ./boxen stop v3-cloud
    if ./boxen exec v3-cloud git ls-remote "https://github.com/$BOXEN_TEST_PRIVATE_REPO" HEAD </dev/null >>"$GATE_LOG" 2>&1; then
      say 'secret set after create: needs restart'
    else
      gate_fail 'secret set after create: not applied even after a restart'
    fi
  fi
else
  gate_fail 'boxen auth github after create'
fi

say "=== 3. egress (log: $EGRESS_LOG)"
: > "$EGRESS_LOG"
expect 'npm registry reachable' 200 ./boxen exec v3-cloud curl -sS -o /dev/null --max-time 20 -w '%{http_code}' https://registry.npmjs.org/
# Read only with the policy note: 000 under deny-by-default is the expected
# denial; under allow-all it is a failure.
example="$(./boxen exec v3-cloud curl -sS -o /dev/null --max-time 20 -w '%{http_code}' https://example.com/ </dev/null 2>>"$EGRESS_LOG")"
printf 'example.com: %s (exit %s); policy: %s\n' "${example:-none}" "$?" "$BOXEN_CLOUD_POLICY_NOTE" | tee -a "$EGRESS_LOG" "$GATE_LOG"

say "=== 4. a preview over SSH, on 127.0.0.1 only"
check 'web server in the box' ./boxen exec v3-cloud sh -c \
  'cd /tmp && (setsid nohup python3 -m http.server 8000 >/dev/null 2>&1 </dev/null &); sleep 2'
check './boxen net v3-cloud 8000' ./boxen net v3-cloud 8000
expect 'request through the tunnel' 200 curl -sS --max-time 10 -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/
expect 'the tunnel listens on 127.0.0.1 only' 127.0.0.1:8000 listeners 8000
check 'boxen net -l lists it' sh -c './boxen net v3-cloud -l | grep -q 8000'
check 'boxen net -r removes it' ./boxen net v3-cloud -r 8000
check 'nothing answers once removed' sh -c '! curl -sS --max-time 5 -o /dev/null http://127.0.0.1:8000/'

say "=== 5. Docker inside the cloud box (recorded for the README)"
record 'docker run' ./boxen exec v3-cloud docker run --rm alpine:3.20 true
./boxen exec v3-cloud sh -c 'mkdir -p /tmp/cg && cat > /tmp/cg/compose.yaml' >>"$GATE_LOG" 2>&1 <<'EOF'
services:
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_HOST_AUTH_METHOD: trust
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 2s
      retries: 30
  app:
    image: alpine:3.20
    command: ["sleep", "300"]
    depends_on:
      db:
        condition: service_healthy
EOF
record 'compose up --wait (120 s)' ./boxen exec v3-cloud sh -c 'cd /tmp/cg && timeout 120 docker compose up -d --wait; echo "exit $?"'
record 'compose down' ./boxen exec v3-cloud sh -c 'cd /tmp/cg && docker compose down; echo "exit $?"'

say "=== 6. stop and resume"
check 'change .hidden' ./boxen exec v3-cloud sh -c 'echo guest > /workspace/.hidden'
id_before="$(id_of v3-cloud)"
# Two empty ids would make the comparison after the resume pass without reading one.
must 'sandbox id listed before the stop' test -n "$id_before"
record 'ttl before the stop' sbx --cloud ttl --json v3-cloud
check './boxen stop v3-cloud' ./boxen stop v3-cloud
wait_for 'stopped' 120 status_is v3-cloud stopped
check './boxen run v3-cloud -- --version resumes it' ./boxen run v3-cloud -- --version
expect 'blob after the resume' "$digest" ./boxen exec v3-cloud sh -c 'sha256sum /workspace/blob | cut -d" " -f1'
expect '.hidden after the resume' guest ./boxen exec v3-cloud cat /workspace/.hidden
expect 'same sandbox id' "$id_before" id_of v3-cloud
record 'ttl after the resume (a fresh period)' sbx --cloud ttl --json v3-cloud

say "=== 7. Codex and Grok in the cloud"
create_sandbox v3-cloud-codex cloud -- ./boxen create v3-cloud-codex --no-copy --cloud --agent codex --plugins none --no-tui
check './boxen check v3-cloud-codex' ./boxen check v3-cloud-codex
check 'stop v3-cloud-codex' ./boxen stop v3-cloud-codex
create_sandbox v3-cloud-grok cloud -- ./boxen create v3-cloud-grok --no-copy --cloud --agent grok --plugins none --no-tui
check 'grok on PATH in a login shell' ./boxen exec v3-cloud-grok bash -lc 'command -v grok'
check 'stop v3-cloud-grok' ./boxen stop v3-cloud-grok

say "=== 8. root work through Docker's sudo"
check 'sudo in the cloud box' ./boxen exec v3-cloud sudo -n true
check './boxen update v3-cloud' ./boxen update v3-cloud
create_sandbox v3-cloud-ts cloud -- ./boxen create v3-cloud-ts --no-copy --cloud --tailscale --no-tui
wait_for 'Tailscale socket' 60 ./boxen exec v3-cloud-ts test -S /var/run/tailscale/tailscaled.sock
record './boxen tailscale status (not logged in yet)' ./boxen tailscale status v3-cloud-ts
if [[ -n "${BOXEN_TEST_TS_KEY:-}" ]]; then
  export BOXEN_TEST_TS_KEY
  check './boxen tailscale join, key on stdin' sh -c 'printf "%s\n" "$BOXEN_TEST_TS_KEY" | ./boxen tailscale join v3-cloud-ts --auth-key-stdin'
  check 'web server in v3-cloud-ts' ./boxen exec v3-cloud-ts sh -c \
    'cd /tmp && (setsid nohup python3 -m http.server 8000 >/dev/null 2>&1 </dev/null &); sleep 2'
  check './boxen tailscale serve v3-cloud-ts 8000' ./boxen tailscale serve v3-cloud-ts 8000
  dns="$(./boxen exec v3-cloud-ts sudo -n tailscale status --json </dev/null | jq -r '.Self.DNSName // empty')"
  expect 'tailnet HTTPS from this laptop' 200 curl -sS --max-time 30 -o /dev/null -w '%{http_code}' "https://${dns%.}/"
else
  say 'SKIP tailnet join and serve: set BOXEN_TEST_TS_KEY'
fi
check 'stop v3-cloud-ts' ./boxen stop v3-cloud-ts
create_sandbox v3-cloud-sb cloud -- ./boxen create v3-cloud-sb --no-copy --cloud --supabase-serve --no-tui
expect 'serve preset recorded' supabase ./boxen exec v3-cloud-sb cat /etc/boxen/serve-preset
# The root helper sees the preset through sudo -n, so a plain port is refused.
check 'the preset reaches the root helper' sh -c 'out="$(./boxen tailscale serve v3-cloud-sb 8000 2>&1)"; status=$?
  printf "%s\n" "$out"; [ "$status" != 0 ] && printf "%s" "$out" | grep -q "The Supabase preset serves :443 from port 3000"'
if [[ -n "${BOXEN_TEST_TS_KEY:-}" ]]; then
  check 'join v3-cloud-sb' sh -c 'printf "%s\n" "$BOXEN_TEST_TS_KEY" | ./boxen tailscale join v3-cloud-sb --auth-key-stdin'
  serve_status="$(./boxen exec v3-cloud-sb sudo -n tailscale serve status </dev/null 2>&1)"
  printf '%s\n' "$serve_status" >> "$GATE_LOG"
  for port in 3000 3010 3001 54321 54323 54324 8000; do
    check "the preset routes port $port" sh -c 'printf "%s" "$0" | grep -q "127.0.0.1:$1"' "$serve_status" "$port"
  done
else
  say 'SKIP the seven Supabase routes: set BOXEN_TEST_TS_KEY'
fi
check 'stop v3-cloud-sb' ./boxen stop v3-cloud-sb

say "=== 9. timings"
say "first cloud create, including the upload: ${upload}s"
gate_end
