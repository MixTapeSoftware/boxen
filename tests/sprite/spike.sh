#!/usr/bin/env bash
# Hand-run spike for the Sprites design (docs/superpowers/specs/
# 2026-10-29-sprites-design.md, "Spike before build"). It creates one
# throwaway Sprite, answers the design's open questions, and destroys the
# Sprite on exit. Run it on a laptop logged in with `sprite login`; it needs
# jq. Nothing here reads a credential: the GitHub Connector check runs only
# when SPIKE_GH_GATEWAY names a connector's gateway URL (not a secret).
#
#   bash tests/sprite/spike.sh               # every automated check
#   SPRITE_ORG=my-team bash tests/sprite/spike.sh
#   SPIKE_GH_GATEWAY=https://api.sprites.dev/v1/gateway/github/conn_x \
#     SPIKE_GH_REPO=owner/private-repo bash tests/sprite/spike.sh
#   SPIKE_KEEP=1 bash tests/sprite/spike.sh  # keep the Sprite for checks 5 and 8
#
# Copy the summary at the end into the design's Review log.
set -uo pipefail
SPRITE="${SPRITE_BIN:-sprite}"
command -v "$SPRITE" >/dev/null 2>&1 || { echo 'Install the sprite CLI first' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo 'Install jq first' >&2; exit 2; }
org=()
if [[ -n "${SPRITE_ORG:-}" ]]; then org=(-o "$SPRITE_ORG"); fi
sprite() { command "$SPRITE" "$@"; }
dir="${BOXEN_VALIDATION_DIR:-local/validation}"
mkdir -p "$dir"
log="$dir/sprite-spike.log"
: > "$log"
name="spike-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
results=()
made=0

say() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$log"; }
note() { results+=("$1"); say "$1"; }
# on NAME CMD...: run CMD inside the Sprite, output to the log.
on() { sprite exec "${org[@]+"${org[@]}"}" -s "$name" -- "$@"; }
api() { sprite api "${org[@]+"${org[@]}"}" "$@"; }
cleanup() {
  if [[ "$made" == 1 ]]; then
    say "--- destroying $name"
    sprite destroy "${org[@]+"${org[@]}"}" --force "$name" >>"$log" 2>&1 ||
      say "Could not destroy $name; remove it with: sprite destroy --force $name"
  fi
  say '=== summary (paste into the Review log)'
  printf '%s\n' "${results[@]+"${results[@]}"}" | tee -a "$log"
  say "Full log: $log"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

say "=== sprite spike, $name"
sprite --version >>"$log" 2>&1 || sprite version >>"$log" 2>&1 || true
say '--- create'
if sprite create "${org[@]+"${org[@]}"}" --skip-console --label boxen "$name" >>"$log" 2>&1; then
  made=1
else
  note 'FAIL create (see log); nothing else ran'
  exit 1
fi
for _ in $(seq 1 60); do on true >/dev/null 2>&1 && break; sleep 1; done

# 1. The user, home and sudo.
who="$(on sh -c 'printf "%s %s\n" "$(whoami)" "$HOME"' 2>>"$log")"
if on sudo -n true >>"$log" 2>&1; then note "1 PASS sudo -n works; user and home: $who"
else note "1 FAIL sudo -n refused; user and home: $who"; fi

# 2. Stdin through exec: a heredoc, a payload over 64 KB, the exit code.
payload="$(head -c 100000 /dev/zero | tr '\0' x)"
got="$(printf 'printf %%s "$(cat <<'"'"'PAYLOAD'"'"'\n%s\nPAYLOAD\n)" | wc -c\n' "$payload" | on bash -s 2>>"$log" | tr -d ' ')"
if [[ "$got" == 100000 ]]; then note '2 PASS a 100 KB heredoc reaches bash -s intact'
else note "2 FAIL heredoc arrived as ${got:-nothing} bytes, not 100000"; fi
on sh -c 'exit 7' >>"$log" 2>&1; status=$?
if [[ "$status" == 7 ]]; then note '2 PASS the exit code propagates'
else note "2 FAIL exit 7 came back as $status"; fi
# sprites-go#51: output written before the client attaches can be lost.
bytes="$(on sh -c 'head -c 200000 /dev/zero' 2>>"$log" | wc -c | tr -d ' ')"
if [[ "$bytes" == 200000 ]]; then note '2 PASS 200 KB of immediate output arrives'
else note "2 INFO 200 KB of immediate output arrived as ${bytes:-0} bytes (sprites-go#51)"; fi

# 9. Which path form sprite api takes for a Sprite's own resources.
form=""
if api -s "$name" /policy/network >>"$log" 2>&1; then form=sprite
elif api "/v1/sprites/$name/policy/network" >>"$log" 2>&1; then form=absolute; fi
case "$form" in
  sprite) note '9 PASS sprite api -s NAME /policy/network reaches the Sprite (the launcher'"'"'s form)'
    # policy_get parses stdout alone; anything else there breaks bxn allow and create.
    if api -s "$name" /policy/network -- -fsS 2>>"$log" | jq -e '.rules | type == "array"' >/dev/null 2>&1; then
      note '9 PASS a GET of /policy/network prints the policy as JSON on stdout alone'
    else note '9 FAIL a GET of /policy/network does not print bare JSON on stdout (see log)'; fi ;;
  absolute) note '9 FAIL only sprite api /v1/sprites/NAME/... works; change sprite_api in lib/box.sh' ;;
  *) note '9 FAIL neither sprite api path form worked (see log)' ;;
esac
policy_post() {
  if [[ "$form" == absolute ]]; then
    api "/v1/sprites/$name/policy/$1" -- -X POST -H 'Content-Type: application/json' --data-binary @-
  else
    api -s "$name" "/policy/$1" -- -X POST -H 'Content-Type: application/json' --data-binary @-
  fi
}

# 3. Network policy from outside, read back from the API and inside, and a
# blocked host. The launcher needs the API read-back; the inside copy is
# checked when the Sprite has one (the first run's Sprite had none).
printf '%s' '{"rules":[{"include":"defaults"},{"domain":"example.com","action":"allow"}]}' |
  policy_post network >>"$log" 2>&1
has_example='[.rules[]? | select(.domain == "example.com")] | length == 1'
if api -s "$name" /policy/network -- -fsS 2>>"$log" | jq -e "$has_example" >/dev/null 2>&1; then
  note '3 PASS the posted policy reads back from the API'
else note '3 FAIL the posted policy did not read back from the API'; fi
if on test -e /.sprite/policy/network.json >>"$log" 2>&1; then
  sleep 2
  inside="$(on cat /.sprite/policy/network.json 2>>"$log")"
  printf '%s\n' "$inside" >>"$log"
  if printf '%s' "$inside" | jq -e "$has_example" >/dev/null 2>&1; then
    note '3 PASS the posted policy reads back at /.sprite/policy/network.json'
  else note '3 FAIL /.sprite/policy/network.json exists but does not hold the posted policy'; fi
else
  on ls -la /.sprite /.sprite/policy >>"$log" 2>&1 || true
  note '3 INFO the Sprite has no /.sprite/policy/network.json (the launcher relies on the API)'
fi
if on sh -c 'echo x > /.sprite/policy/network.json' >>"$log" 2>&1 ||
   on sudo -n sh -c 'echo x > /.sprite/policy/network.json' >>"$log" 2>&1; then
  note '3 FAIL the Sprite could write its own policy file'
else note '3 PASS the Sprite cannot write its own policy file, even with sudo'; fi
start=$(date +%s)
if on curl -fsS -m 20 -o /dev/null https://example.org >>"$log" 2>&1; then
  note '3 FAIL example.org, not in the policy, was reachable'
else note "3 PASS example.org is refused, in $(( $(date +%s) - start ))s"; fi
if on curl -fsS -m 20 -o /dev/null https://example.com >>"$log" 2>&1; then note '3 PASS example.com, allowed, is reachable'
else note '3 FAIL example.com, allowed, was not reachable'; fi
# lock_down's probe: getent must fail for a blocked host and work for an allowed one.
if on getent hosts example.org >>"$log" 2>&1; then note '3 FAIL getent resolves example.org, which is blocked'
elif on getent hosts example.com >>"$log" 2>&1; then note '3 PASS getent: example.org blocked, example.com resolves (the lock-down probe)'
else note '3 FAIL getent resolves neither host; the lock-down probe cannot tell blocked from broken'; fi
# Base provisioning's hosts must resolve under the shipped baseline.
if [[ -f policies/sprite-baseline.json ]]; then
  policy_post network < policies/sprite-baseline.json >>"$log" 2>&1
  for host in archive.ubuntu.com github.com raw.githubusercontent.com mise.en.dev nodejs.org; do
    if on curl -sS -m 20 -o /dev/null "https://$host" >>"$log" 2>&1; then note "3 PASS baseline reaches $host"
    else note "3 FAIL baseline does not reach $host"; fi
  done
fi
printf '%s' '{"rules":[{"include":"defaults"}]}' | policy_post network >>"$log" 2>&1

# 4. Docker under the standard and privileged profiles, with the docker
# plugin's hosts allowed: Docker Hub's blobs come from a CDN outside defaults.
if [[ -f plugins/docker.sh ]]; then
  docker_hosts="$(PLUGIN_EGRESS_HOSTS=''; . plugins/docker.sh; printf '%s' "$PLUGIN_EGRESS_HOSTS")"
  # shellcheck disable=SC2086 # one argument per host
  jq -c --args '.rules += [$ARGS.positional[] | {domain: ., action: "allow"}]' $docker_hosts \
    < policies/sprite-baseline.json | policy_post network >>"$log" 2>&1
fi
on sudo -n sh -c 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq docker.io' >>"$log" 2>&1 ||
  note '4 FAIL apt-get install docker.io'
for profile in standard privileged; do
  printf '{"profile":"%s"}' "$profile" | policy_post privileges >>"$log" 2>&1
  on sudo -n sh -c 'pkill dockerd; sleep 1; (dockerd >/tmp/dockerd.log 2>&1 &); sleep 8; docker run --rm hello-world' >>"$log" 2>&1
  if [[ $? == 0 ]]; then note "4 PASS docker run hello-world works with privileges $profile"
  else note "4 FAIL docker run hello-world fails with privileges $profile (see /tmp/dockerd.log in the log)"; fi
  on sudo -n tail -20 /tmp/dockerd.log >>"$log" 2>&1
done
if on sh -c 'command -v sprite-env' >>"$log" 2>&1; then
  # Stop the loop's dockerd, or docker info passes without the service.
  on sudo -n sh -c 'pkill dockerd; sleep 1' >>"$log" 2>&1
  on sh -c 'sprite-env services create dockerd --cmd /usr/bin/sudo --args "-n,$(PATH="$PATH:/usr/sbin"; command -v dockerd)" --duration 10s' >>"$log" 2>&1
  if on sh -c 'sleep 3; sudo -n docker info >/dev/null' >>"$log" 2>&1; then note '4 PASS dockerd runs as a sprite-env service through sudo'
  else note '4 FAIL dockerd as a sprite-env service through sudo'; fi
fi

# 5. URL access: what the API reports, and what a non-admin member sees.
api -s "$name" / >>"$log" 2>&1 || api "/v1/sprites/$name" >>"$log" 2>&1 || true
sprite info "${org[@]+"${org[@]}"}" -s "$name" >>"$log" 2>&1 || true
note "5 MANUAL have a non-admin org member open the URL in the log while $name exists; record whether they reach it"

# 6. GitHub Connector through the gateway.
if [[ -n "${SPIKE_GH_GATEWAY:-}" ]]; then
  if on curl -fsS -m 30 "${SPIKE_GH_GATEWAY%/}/user" >>"$log" 2>&1; then note '6 PASS the gateway answers GET /user from inside the Sprite'
  else note '6 FAIL GET /user through the gateway'; fi
  if [[ -n "${SPIKE_GH_REPO:-}" ]]; then
    if on git ls-remote "${SPIKE_GH_GATEWAY%/}/$SPIKE_GH_REPO.git" >>"$log" 2>&1; then note '6 PASS git ls-remote works through the gateway'
    else note '6 FAIL git over the gateway (phase 2 needs another route for git)'; fi
  fi
else
  note '6 SKIP set SPIKE_GH_GATEWAY (and SPIKE_GH_REPO) to test a GitHub Connector'
fi

# 7. Whether a checkpoint can seed a new Sprite.
sprite checkpoint create "${org[@]+"${org[@]}"}" -s "$name" --comment spike >>"$log" 2>&1 &&
  note '7 PASS checkpoint create' || note '7 FAIL checkpoint create'
if sprite create --help 2>&1 | grep -Eiq 'checkpoint|from'; then
  note '7 INFO sprite create --help mentions a checkpoint or source; see the log'
else note '7 INFO sprite create has no flag to start from a checkpoint'; fi
sprite create --help >>"$log" 2>&1 || true

# 8. Login shells and .zshenv.
on sh -c 'printf "export SPIKE_ZSHENV=yes\n" >> "$HOME/.zshenv"' >>"$log" 2>&1
on sudo -n chsh -s "$(on sh -c 'command -v zsh' 2>/dev/null)" sprite >>"$log" 2>&1
shell="$(on sh -c 'getent passwd sprite | cut -d: -f7' 2>>"$log")"
note "8 INFO the sprite user's login shell after chsh: ${shell:-unknown}"
plain="$(on sh -c 'printf %s "${SPIKE_ZSHENV:-no}"' 2>>"$log")"
viazsh="$(on zsh -c 'printf %s "${SPIKE_ZSHENV:-no}"' 2>>"$log")"
note "8 INFO .zshenv seen by plain exec: $plain; by exec zsh -c: $viazsh"
note "8 MANUAL run: sprite console -s $name, then echo \$SPIKE_ZSHENV \$0 (yes and -zsh mean a login zsh)"

# 10. Labels as the launcher sets them.
if sprite list "${org[@]+"${org[@]}"}" --prefix "$name" >>"$log" 2>&1; then note '10 PASS sprite list --prefix finds the Sprite'
else note '10 FAIL sprite list --prefix'; fi
if [[ "${SPIKE_KEEP:-0}" == 1 ]]; then made=0; note "Kept $name for the manual checks; remove it with: sprite destroy --force $name"; fi
