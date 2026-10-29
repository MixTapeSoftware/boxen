# Sourced by bxn. The plugin contract and Sprite policies; Bash 3.2.
#
# Plugins and the launcher reach a Sprite only through these functions:
#   box_root CMD...         run as root (sudo -n), stdin passed through
#   box_user CMD...         run as the Sprite's user, stdin passed through
#   box_set_env NAME VALUE  a variable every shell and the agent see
#   box_guest root|user SCRIPT [ARGS...]
#                           run one of Boxen's guest scripts
# BOX_NAME names the Sprite; BOX_BACKEND, BOX_USER and BOX_HOME describe it,
# and BOX_AGENT is its agent: shell, claude, codex or grok.
# The caller defines die, warn and log. Secrets travel on stdin, never in an
# argument, an --env flag or a log.

BOX_BACKEND=sprite
BOX_USER=sprite
BOX_HOME=/home/sprite
BOX_GUEST=/usr/local/share/boxen
BOX_NAME=""
BOX_AGENT=shell
SPRITE_BIN="${SPRITE_BIN:-sprite}"
# The Fly organization, when the teammate belongs to more than one.
SPRITE_ORG=()
if [[ -n "${BOXEN_SPRITE_ORG:-}" ]]; then SPRITE_ORG=(-o "$BOXEN_SPRITE_ORG"); fi
# Where a policy file lives, and the baseline every Sprite starts from.
BOX_BASELINE="${BOXEN_BASELINE:-$PROJECT_DIR/policies/sprite-baseline.json}"

# Call sprite by the path need_sprite resolved. Not `command sprite`: in Bash
# 3.2 a failing `command` inside a function exits under set -e even within ||.
SPRITE_PATH=""
need_sprite() {
  SPRITE_PATH="$(type -P "$SPRITE_BIN")" ||
    die 'Install the sprite CLI (https://docs.fly.io/sprites/cli/installation) and run sprite login.'
}
# sprite SUBCOMMAND... with the organization flag after the subcommand words
# a caller passes in SUB (one word, or two such as "checkpoint create").
sprite_cmd() {
  local sub="$1" words=()
  shift
  read -r -a words <<< "$sub"
  "$SPRITE_PATH" "${words[@]}" ${SPRITE_ORG[@]+"${SPRITE_ORG[@]}"} "$@"
}
# sprite_exec NAME [EXEC FLAGS...] -- CMD...
sprite_exec() {
  local name="$1"
  shift
  sprite_cmd exec -s "$name" "$@"
}
# sprite_api NAME PATH [CURL ARGS...]: the Sprites API for one Sprite's own
# resources, through the CLI's stored login, so no token is ever handled
# here. The path form is the one tests/sprite/spike.sh checks (item 9).
sprite_api() {
  local name="$1" path="$2"
  shift 2
  sprite_cmd api -s "$name" "$path" -- -fsS "$@"
}

# No port forwarding: sprite exec otherwise binds any port a command opens,
# such as a check's ChromeDriver, on this machine.
box_root() { sprite_exec "$BOX_NAME" --no-port-forward -- sudo -n "$@"; }
box_user() { sprite_exec "$BOX_NAME" --no-port-forward -- "$@"; }
box_guest() {
  local who="$1" script="$2"
  shift 2
  case "$who" in
    root) box_root bash "$BOX_GUEST/$script" "$@" ;;
    user) box_user bash "$BOX_GUEST/$script" "$@" ;;
    *) die "box_guest: root or user, not $who" ;;
  esac
}
# VALUE in single quotes, which every POSIX shell reads back as it was;
# printf %q can write bash-only $'...' quoting, and sh sources these files.
sh_quote() {
  local q="'\\''"
  printf "'%s'" "${1//\'/$q}"
}
# The value goes out on stdin as a quoted export line and replaces any
# earlier one; ~/.config/boxen/env.sh is private to the user. The Sprite and
# its agent can read it.
box_set_env() {
  printf 'export %s=%s\n' "$1" "$(sh_quote "$2")" | box_user sh -c '
    umask 077
    dir="$HOME/.config/boxen"; file="$dir/env.sh"
    mkdir -p "$dir"; touch "$file"
    grep -v "^export $1=" "$file" > "$file.tmp" || true
    cat >> "$file.tmp"
    mv "$file.tmp" "$file"' sh "$1"
}
# Copy guest/ to /usr/local/share/boxen and env.sh to /etc/boxen, over stdin.
box_upload_guest() {
  local mac=()
  if tar --version 2>/dev/null | grep -q bsdtar; then mac=(--no-mac-metadata --no-xattrs); fi
  COPYFILE_DISABLE=1 tar -cf - ${mac[@]+"${mac[@]}"} -C "$PROJECT_DIR/guest" . |
    box_root sh -c '
      set -e
      mkdir -p "$1" /etc/boxen
      tar --no-same-owner -xf - -C "$1"
      chmod -R a+rX "$1"
      install -m 644 "$1/env.sh" /etc/boxen/env.sh' sh "$BOX_GUEST"
}

# --- Policies ------------------------------------------------------------------

# A domain rule's pattern: a host, or *. and a host. Lowercase.
valid_host() {
  local re='^(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
  [[ "$1" =~ $re && ${#1} -le 253 ]]
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# policy_document HOST...: the baseline plus an allow rule for each host not
# already allowed, in order. Prints compact JSON.
policy_document() {
  jq -c --args '
    reduce ($ARGS.positional[] | select(length > 0)) as $h (.;
      if any(.rules[]; .domain == $h and .action == "allow") then .
      else .rules += [{"domain": $h, "action": "allow"}] end)' "$@" < "$BOX_BASELINE"
}
# policy_merge HOST... < CURRENT: the current policy plus the hosts, for
# bxn allow. Read, merge, post the whole document: never a blind append.
policy_merge() {
  jq -c --args '
    .rules = (.rules // [])
    | reduce ($ARGS.positional[] | select(length > 0)) as $h (.;
        if any(.rules[]; .domain == $h and .action == "allow") then .
        else .rules += [{"domain": $h, "action": "allow"}] end)' "$@"
}
# policy_covers ENFORCED DOCUMENT: the Sprite enforces every rule set, and is
# not unrestricted unless the document asked for that. The Sprite may add or
# expand rules of its own, so this is a subset check, not equality.
policy_covers() {
  printf '%s' "$1" | jq -e --argjson doc "$2" '
    def key: [(.domain // ""), (.action // ""), (.include // "")];
    (.rules // []) as $in
    | if ($doc.rules | length) == 0 then ($in | length) == 0
      else ($in | length) > 0 and ($doc.rules | all(key as $k | $in | any(.[]; key == $k))) end
  ' >/dev/null 2>&1
}
# policy_set NAME < DOCUMENT
policy_set() {
  sprite_api "$1" /policy/network -X POST -H 'Content-Type: application/json' --data-binary @- >/dev/null
}
policy_get() { sprite_api "$1" /policy/network </dev/null; }
# What the Sprite itself enforces: its read-only copy of the policy.
policy_inside() { sprite_exec "$1" -- cat /.sprite/policy/network.json; }
privileges_set() {
  printf '{"profile":"%s"}' "$2" |
    sprite_api "$1" /policy/privileges -X POST -H 'Content-Type: application/json' --data-binary @- >/dev/null
}
privileges_get() { sprite_api "$1" /policy/privileges </dev/null | jq -r '.profile // ""'; }
# lock_down NAME PROFILE DOCUMENT: apply both policies, then read them back:
# the network policy from inside the Sprite, the profile from the API. Any
# failure returns non-zero, and the caller destroys the Sprite.
lock_down() {
  local name="$1" profile="$2" document="$3" inside="" attempt=0
  printf '%s' "$document" | policy_set "$name" || return 1
  privileges_set "$name" "$profile" || return 1
  # The Sprite reloads its copy live; give it a few seconds to land.
  while :; do
    inside="$(policy_inside "$name" </dev/null 2>/dev/null)" || inside=""
    if policy_covers "$inside" "$document"; then break; fi
    attempt=$((attempt + 1))
    [[ "$attempt" -lt "${BOXEN_POLICY_WAIT:-10}" ]] || break
    sleep 1
  done
  policy_covers "$inside" "$document" || { warn "The network policy in $name does not match what was set."; return 1; }
  [[ "$(privileges_get "$name")" == "$profile" ]] || { warn "The privileges profile of $name is not $profile."; return 1; }
}

# --- Plugins -------------------------------------------------------------------

# A plugin is plugins/ID.sh (plugins/agents/NAME.sh for an agent). It may set
#   PLUGIN_REQUIRES      plugins it needs, selected with it
#   PLUGIN_PRIVILEGES    standard (default) or privileged
#   PLUGIN_EGRESS_HOSTS  hosts its install and runtime reach, kept allowed
# and define plugin_install, and plugin_is_installed to skip the install.
# Each runs in a subshell, so one plugin's names never leak into the next.
# The caller tests plugin_run's status, which turns set -e off inside it, so
# a plugin_install with several steps chains them with &&.
plugin_file() {
  case "$1" in
    agent:*) printf '%s/plugins/agents/%s.sh\n' "$PROJECT_DIR" "${1#agent:}" ;;
    *) printf '%s/plugins/%s.sh\n' "$PROJECT_DIR" "$1" ;;
  esac
}
# plugin_meta ID VARIABLE: one metadata field.
plugin_meta() {
  local file
  file="$(plugin_file "$1")"
  [[ -f "$file" ]] || return 0
  (
    PLUGIN_REQUIRES="" PLUGIN_PRIVILEGES=standard PLUGIN_EGRESS_HOSTS=""
    # shellcheck disable=SC1090
    source "$file"
    eval "printf '%s\n' \"\${$2}\""
  )
}
plugin_run() {
  local file
  file="$(plugin_file "$1")"
  [[ -f "$file" ]] || die "No plugin file for $1"
  (
    set -e
    plugin_is_installed() { return 1; }
    # shellcheck disable=SC1090
    source "$file"
    if plugin_is_installed; then exit 0; fi
    plugin_install
  )
}
