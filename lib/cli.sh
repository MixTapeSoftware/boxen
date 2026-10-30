# Sourced by bxn. Boxen on Fly.io Sprites. Credentials are never accepted as
# command arguments. Bash 3.2: no associative arrays; guard empty arrays
# under set -u.

AGENTS="shell claude codex grok"
PLUGIN_INDEX="$PROJECT_DIR/plugins/plugins.tsv"
# Every plugin, in install order, and the ones selected by default.
PLUGINS="$(awk -F'\t' 'NR > 1 { printf "%s ", $1 }' "$PLUGIN_INDEX")"
PLUGINS="${PLUGINS% }"
DEFAULT_PLUGINS="$(awk -F'\t' 'NR > 1 && $2 == "yes" { printf "%s,", $1 }' "$PLUGIN_INDEX")"
DEFAULT_PLUGINS="${DEFAULT_PLUGINS%,}"
CONFIG_DIR="${BOXEN_CONFIG_DIR:-$HOME/.config/boxen}"
HANDLE_FILE="$CONFIG_DIR/handle"
# Handles this teammate used before, one per line: their Sprites keep the old
# prefix and stay reachable by full name.
FORMER_HANDLES_FILE="$CONFIG_DIR/former-handles"
# Supabase's local stack: the app's dev server, and the ports supabase start
# uses unless the repo's supabase/config.toml moves them.
SUPABASE_APP_PORT=3000
SUPABASE_DEFAULTS="api=54321 db=54322 studio=54323 inbucket=54324"

die() { printf 'bxn: %s\n' "$*" >&2; exit 1; }
log() { printf '[+] %s\n' "$*"; }
warn() { printf 'bxn: %s\n' "$*" >&2; }
need_value() { [[ $# -ge 2 && -n "$2" ]] || die "Missing value for $1"; }
need_jq() { command -v jq >/dev/null 2>&1 || die 'Install jq; bxn reads and writes Sprite policies with it.'; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
terminal() { [[ -t 0 && -t 1 ]]; }
has_plugin() { [[ ",$selected," == *",$1,"* ]]; }
add_plugin() { has_plugin "$1" || selected="${selected:+$selected,}$1"; }
drop_plugin() {
  selected=",$selected,"
  selected="${selected/,$1,/,}"
  selected="${selected#,}"; selected="${selected%,}"
}
# One line a shell reads back the same way: plain words bare, the rest quoted.
print_command() {
  local arg out="" safe='^[A-Za-z0-9_./:=+@%,-]+$'
  for arg in "$@"; do
    if [[ "$arg" =~ $safe ]]; then out="$out $arg"
    elif [[ "$arg" != *"'"* ]]; then out="$out '$arg'"
    else out="$out $(printf '%q' "$arg")"; fi
  done
  printf '%s\n' "${out# }"
}
set_agent() {
  [[ -z "$agent" || "$agent" == "$1" ]] ||
    die "One agent per Sprite: got $agent and $1. Create a second Sprite for the other agent."
  agent="$1"
}

usage() {
  cat <<'EOF'
bxn create PROJECT [REPO] [options]          (also: init, -i)
  REPO                           owner/repo or an https URL; default: the
                                 current directory's origin. Cloned into /workspace
  --no-clone                     Start with an empty /workspace
  --agent shell|claude|codex|grok
                                 One per Sprite. Default: shell
  --claude --codex --grok        Shorthand for --agent
  --plugins all|none|ID,ID,...
                                 Default: none; nothing is assumed
  --ID                           Add plugin ID, such as --docker or --nvchad
  --gh-token                     Same as --gh-auth
  --gh-token-stdin               Read the GitHub token from stdin's first line
  --allow HOST                   Also allow HOST (repeatable; *.example.com works)
  --allow-all                    No network policy at all (warns)
  --no-tui                       Skip the interactive selector
  --detach                       Do not open a shell when done
  --dry-run                      Print the plan without creating anything

bxn PROJECT                                  Open zsh in /workspace
bxn shell PROJECT [COMMAND...]               (also: -s)
bxn run PROJECT [-- ARGS...]                 Start the agent
bxn exec PROJECT COMMAND [ARGS...]           Run a command
bxn clone PROJECT [REPO]                     Clone into an empty /workspace
bxn list [--all]                             Your Sprites, or the whole org's (also: ls)
bxn delete PROJECT [--yes]                   (also: destroy, -d)
bxn allow PROJECT HOST...                    Allow more hosts
bxn policy PROJECT                           Show the network and privileges policy
bxn env PROJECT VAR                          (also: -e) Set a variable; prompts silently
bxn auth github PROJECT                      Store a GitHub token (prompt or stdin)
bxn checkpoint PROJECT [COMMENT]             Snapshot the whole filesystem
bxn checkpoints PROJECT                      List snapshots
bxn restore PROJECT ID [--yes]               Roll back to a snapshot
bxn proxy PROJECT PORT|LOCAL:REMOTE...|supabase
                                             Forward ports to this machine
bxn url PROJECT                              The Sprite's private URL
bxn check PROJECT                            Check the installed plugins
bxn plugins                                  List the plugins
bxn handle [NEW]                             Show or set your Sprite name prefix
bxn doctor                                   Check prerequisites

Sprites are named HANDLE-AGENT-PROJECT: bxn create web --claude makes
HANDLE-claude-web. Other commands take the project alone when one agent's
Sprite has it, else AGENT-PROJECT, or the full name. Commands never create
a Sprite; only create does.
EOF
}

# --- Names -------------------------------------------------------------------

valid_sprite_name() {
  local re='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
  [[ "$1" =~ $re && ${#1} -le 63 ]]
}
# The local user name as a handle: lowercase, other characters as hyphens.
default_handle() {
  printf '%s' "${USER:-me}" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-]/-/g' -e 's/^-*//' -e 's/-*$//' | cut -c1-20
}
valid_handle() { valid_sprite_name "$1" && [[ ${#1} -le 20 ]]; }
# The prefix of every Sprite this teammate makes, chosen on first use.
# Connector name-prefix policies key on it, and it tells the team whose
# Sprite is whose. ensure_handle runs outside any $(...), so it can ask.
HANDLE=""
ensure_handle() {
  local answer suggested
  [[ -z "$HANDLE" ]] || return 0
  if [[ -f "$HANDLE_FILE" ]]; then
    HANDLE="$(head -1 "$HANDLE_FILE")"
    valid_handle "$HANDLE" || die "$HANDLE_FILE holds '$HANDLE', which is not a valid handle; set one with bxn handle NEW."
    return 0
  fi
  suggested="$(default_handle)"
  if terminal; then
    printf 'Your Sprites are named HANDLE-AGENT-PROJECT, so the team can see whose is whose.\n'
    read_value answer "Handle [$suggested]: "
    HANDLE="${answer:-$suggested}"
  else
    HANDLE="$suggested"
  fi
  valid_handle "$HANDLE" || die "Invalid handle: $HANDLE. Use 1-20 lowercase letters, digits and hyphens; set one with bxn handle NEW."
  mkdir -p "$CONFIG_DIR"
  printf '%s\n' "$HANDLE" > "$HANDLE_FILE"
  log "Saved your handle, $HANDLE, in $HANDLE_FILE"
}
handle() { ensure_handle; printf '%s\n' "$HANDLE"; }
# sprite_name PROJECT AGENT: HANDLE-AGENT-PROJECT, so the list shows whose
# Sprite it is and which agent runs in it. A full name passes through, and a
# project already starting with the agent is not doubled.
sprite_name() {
  local name
  [[ -n "$HANDLE" ]] || die 'internal: ensure_handle first'
  case "$1" in
    "$HANDLE"-*) name="$1" ;;
    "$2"-*) name="$HANDLE-$1" ;;
    *) name="$HANDLE-$2-$1" ;;
  esac
  valid_sprite_name "$name" ||
    die "Invalid name: $name. Use lowercase letters, digits and hyphens, 63 characters at most."
  printf '%s\n' "$name"
}
# 0 when the Sprite exists, 1 when not; a failed listing ends bxn, since it
# is not proof that a name is free.
sprite_exists() {
  local names
  names="$(sprite_cmd list --prefix "$1" </dev/null 2>/dev/null)" ||
    die 'sprite list failed. Log in with sprite login, then check bxn doctor.'
  printf '%s\n' "$names" | awk '{ print $1 }' | grep -Fxq -- "$1"
}
# 0 when NAME is a full Sprite name under a handle this teammate used before.
former_handle_name() {
  local old
  [[ -f "$FORMER_HANDLES_FILE" ]] || return 1
  valid_sprite_name "$1" || return 1
  while IFS= read -r old || [[ -n "$old" ]]; do
    valid_handle "$old" || continue
    [[ "$1" == "$old"-* ]] && return 0
  done < "$FORMER_HANDLES_FILE"
  return 1
}
# The Sprites for PROJECT under the current handle, one per agent, a name a
# line.
sprites_for_project() {
  local names agent
  names="$(sprite_cmd list --prefix "$HANDLE-" </dev/null 2>/dev/null)" ||
    die 'sprite list failed. Log in with sprite login, then check bxn doctor.'
  for agent in $AGENTS; do
    printf '%s\n' "$names" | awk '{ print $1 }' | grep -Fx -- "$HANDLE-$agent-$1" || true
  done
}
# Sets BOX_NAME for a command that takes PROJECT; never creates anything.
# PROJECT may be AGENT-PROJECT, a full name, or the project alone when one
# agent's Sprite has it. A full name under a former handle is the fallback.
need_sprite_named() {
  local name found
  need_sprite
  ensure_handle
  case "$1" in "$HANDLE"-*) name="$1" ;; *) name="$HANDLE-$1" ;; esac
  if valid_sprite_name "$name" && sprite_exists "$name"; then BOX_NAME="$name"; return 0; fi
  if former_handle_name "$1" && sprite_exists "$1"; then BOX_NAME="$1"; return 0; fi
  if valid_sprite_name "$name"; then
    found="$(sprites_for_project "$1")"
    case "$(printf '%s' "$found" | grep -c .)" in
      0) ;;
      1) BOX_NAME="$found"; return 0 ;;
      *) die "More than one Sprite for $1: $(printf '%s' "$found" | tr '\n' ' ')- name one with its agent, such as ${found%%$'\n'*}." ;;
    esac
  fi
  die "No Sprite for $1 (see bxn list). Nothing was created; use bxn create $1."
}

# --- Repositories ------------------------------------------------------------

# owner/repo, an https URL, or a GitHub SSH remote, as an https URL to clone.
# Returns 2 for an https URL with a user, token, query or fragment in it,
# which bxn never prints or passes on.
repo_url() {
  local ref="$1" slug='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' path authority
  case "$ref" in
    https://*)
      authority="${ref#https://}"; authority="${authority%%[/?#]*}"
      [[ "$authority" != *@* && "$ref" != *[?#]* ]] || return 2
      printf '%s\n' "$ref" ;;
    git@github.com:*) path="${ref#git@github.com:}"; printf 'https://github.com/%s\n' "${path%.git}.git" ;;
    ssh://git@github.com/*) path="${ref#ssh://git@github.com/}"; printf 'https://github.com/%s\n' "${path%.git}.git" ;;
    *)
      [[ "$ref" =~ $slug ]] || return 1
      printf 'https://github.com/%s.git\n' "${ref%.git}" ;;
  esac
}

# clone_url [REPO]: REPO, or else the current directory's origin, as the https
# URL to clone. Exits with the reason when there is none.
clone_url() {
  local repo="${1:-}" url
  if [[ -z "$repo" ]]; then
    repo="$(git config --get remote.origin.url 2>/dev/null || true)"
    [[ -n "$repo" ]] || die 'Name a repository (owner/repo or an https URL), run bxn inside a clone, or pass --no-clone.'
  fi
  url="$(repo_url "$repo")" || case $? in
    2) die 'The repository URL holds a user name, token or query, which bxn never prints or passes on. Name it as owner/repo; for a private repository, store a token with bxn auth github PROJECT.' ;;
    *) die "Not a repository bxn can clone: $repo (use owner/repo or an https URL)" ;;
  esac
  printf '%s\n' "$url"
}
# clone_workspace URL: clone into the Sprite's /workspace with its
# environment loaded, so Git reaches GH_TOKEN through gh. Refuses a
# /workspace that already holds files, such as a clone that stopped partway.
clone_workspace() {
  box_user bash -c '
    . /etc/boxen/env.sh
    dir="$HOME/workspace"
    if [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
      echo "boxen: /workspace is not empty; empty it, then clone again" >&2
      exit 3
    fi
    git clone -- "$1" "$dir"' bash "$1" </dev/null
}

# --- Agents ------------------------------------------------------------------

# Run a guest script as the Sprite's user. Set GUEST_TTY=(--tty) when it
# needs a terminal.
GUEST_TTY=()
guest_script() {
  local script="$1"
  shift
  sprite_exec "$BOX_NAME" --no-port-forward ${GUEST_TTY[@]+"${GUEST_TTY[@]}"} -- bash "$BOX_GUEST/$script" "$@"
}
# Offer the agent's subscription sign-in on the way in when it needs one.
# Terminal only; anything unexpected skips the offer instead of blocking.
offer_agent_login() {
  local status=0 answer agent
  terminal || return 0
  GUEST_TTY=()
  agent="$(guest_script agent-login.sh status </dev/null 2>/dev/null)" || status=$?
  [[ "$status" == 10 ]] || return 0
  if [[ "$agent" == claude ]]; then
    printf 'Claude Code is not signed in yet: start it with bxn run %s and sign in with /login,\n' "$1"
    printf 'using your own subscription.\n'
    return 0
  fi
  read_value answer "$1's agent is not signed in. Sign in to your subscription now? [Y/n] "
  case "$answer" in n|N|no|No|NO) return 0 ;; esac
  GUEST_TTY=(--tty)
  guest_script agent-login.sh login ||
    warn "Sign-in did not finish; bxn $1 offers it again."
  GUEST_TTY=()
}

# --- Create ------------------------------------------------------------------

# A create that failed after the Sprite exists: offer to destroy it, as a
# half-made Sprite is not what anyone asked for.
build_failed() {
  local answer
  trap - INT TERM
  printf 'bxn: Sprite %s was created, but %s failed.\n' "$BOX_NAME" "$1" >&2
  if terminal; then
    read_value answer "Destroy $BOX_NAME? [Y/n] "
    case "$answer" in
      n|N|no|No|NO) ;;
      *) sprite_cmd destroy --force "$BOX_NAME" </dev/null && log "Destroyed $BOX_NAME"; exit 1 ;;
    esac
  fi
  printf 'Look inside with: bxn shell %s\n' "$BOX_NAME" >&2
  printf 'To start over: bxn delete %s, then run create again.\n' "$BOX_NAME" >&2
  exit 1
}
# Lock-down failed: the Sprite may be unrestricted, so it never survives.
unsafe_sprite() {
  trap - INT TERM
  warn "Could not apply and verify the policies on $BOX_NAME, so it was destroyed before anything was installed."
  sprite_cmd destroy --force "$BOX_NAME" </dev/null >/dev/null 2>&1 ||
    warn "Destroying $BOX_NAME failed too; remove it now with: sprite destroy --force $BOX_NAME"
  exit 1
}
# Every plugin a selection needs, added in place.
add_requirements() {
  local item need changed=1
  while [[ "$changed" == 1 ]]; do
    changed=0
    for item in $PLUGINS; do
      has_plugin "$item" || continue
      for need in $(plugin_meta "$item" PLUGIN_REQUIRES); do
        if ! has_plugin "$need"; then add_plugin "$need"; changed=1; fi
      done
    done
  done
}
# The selection in install order.
ordered_plugins() {
  local item out=""
  for item in $PLUGINS; do
    if has_plugin "$item"; then out="${out:+$out,}$item"; fi
  done
  printf '%s\n' "$out"
}

create() {
  local project="" repo="" no_clone=0 agent="" requested="$DEFAULT_PLUGINS" flagged=""
  local dry=0 tui=1 chose_plugins=0 detach=0 allow_all=0 gh_stdin=0
  local selected="" item hosts="" host profile=standard document url="" value identity
  local gh_token="" op_token="" xai_key="" created="" items=() extra=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent) need_value "$@"; set_agent "$2"; shift 2 ;;
      --claude|--claude-code) set_agent claude; shift ;;
      --codex) set_agent codex; shift ;;
      --grok) set_agent grok; shift ;;
      --plugins) need_value "$@"; requested="$2"; chose_plugins=1; shift 2 ;;
      --gh-token) flagged="${flagged:+$flagged,}gh-auth"; shift ;;
      # The token is the first line of stdin: no terminal, nothing in argv.
      --gh-token-stdin) gh_stdin=1; flagged="${flagged:+$flagged,}gh-auth"; shift ;;
      --allow)
        need_value "$@"
        host="$(lower "$2")"
        valid_host "$host" || die "Not a host name: $2 (use example.com or *.example.com)"
        extra+=("$host"); shift 2 ;;
      --allow-all) allow_all=1; shift ;;
      --no-clone) no_clone=1; shift ;;
      --no-tui) tui=0; shift ;;
      --detach) detach=1; shift ;;
      --dry-run) dry=1; shift ;;
      --tailscale) die 'Tailscale is gone: use bxn proxy PROJECT PORT, or the Sprite'"'"'s private URL (bxn url).' ;;
      --open-network) die 'Use --allow HOST for each host, or --allow-all.' ;;
      -p|--path|--mode|--copy-all|--ack-env) die 'Sprites clone a repository instead of copying a directory: bxn create PROJECT owner/repo' ;;
      -h|--help) usage; return ;;
      --*)
        in_list "${1#--}" "$PLUGINS" || die "Unknown create option: $1 (see bxn create --help and bxn plugins)"
        flagged="${flagged:+$flagged,}${1#--}"; shift ;;
      -*) die "Unknown create option: $1" ;;
      *)
        if [[ -z "$project" ]]; then project="$1"
        elif [[ -z "$repo" ]]; then repo="$1"
        else die 'create takes a project name and at most one repository'; fi
        shift ;;
    esac
  done
  [[ -n "$project" ]] || die 'create requires a project name'
  agent="${agent:-shell}"
  in_list "$agent" "$AGENTS" || die "Unknown agent: $agent"
  case "$requested" in
    default) requested="$DEFAULT_PLUGINS" ;;
    all) requested="${PLUGINS// /,}" ;;
    none) requested="" ;;
  esac
  IFS=, read -r -a items <<< "${requested}${flagged:+,$flagged}"
  for item in "${items[@]+"${items[@]}"}"; do
    case "$item" in
      '') continue ;;
      claude|claude-code|codex|grok) die "Select the agent with --agent (one per Sprite), not --plugins $item." ;;
      tailscale) die 'Tailscale is gone: use bxn proxy PROJECT PORT, or the Sprite'"'"'s private URL (bxn url).' ;;
    esac
    in_list "$item" "$PLUGINS" || die "Unknown plugin: $item (see bxn plugins)"
    add_plugin "$item"
  done
  # Repository: the argument, else the current directory's origin.
  if [[ "$no_clone" == 1 ]]; then
    [[ -z "$repo" ]] || die 'Pass a repository or --no-clone, not both'
  else
    url="$(clone_url "$repo")" || exit 1
  fi
  ensure_handle
  BOX_PROJECT="$project"
  # The selector shows in a terminal unless --plugins already chose.
  if [[ "$tui" == 1 && "$chose_plugins" == 0 ]] && terminal; then tui_select; fi
  # After the selector, which may change the agent.
  BOX_NAME="$(sprite_name "$project" "$agent")"
  add_requirements
  if has_plugin rtkplus; then
    case "$agent" in
      claude|codex) ;;
      *) log "RTK's hook applies to Claude and Codex; rtkplus left out for $agent"; drop_plugin rtkplus ;;
    esac
  fi
  selected="$(ordered_plugins)"
  BOX_AGENT="$agent"
  # The policy: the baseline, the agent's and plugins' hosts, and --allow.
  if [[ "$agent" != shell ]]; then hosts="$(plugin_meta "agent:$agent" PLUGIN_EGRESS_HOSTS)"; fi
  IFS=, read -r -a items <<< "$selected"
  for item in "${items[@]+"${items[@]}"}"; do
    hosts="$hosts $(plugin_meta "$item" PLUGIN_EGRESS_HOSTS)"
    if [[ "$(plugin_meta "$item" PLUGIN_PRIVILEGES)" == privileged ]]; then profile=privileged; fi
  done
  need_jq
  # shellcheck disable=SC2086
  if [[ "$allow_all" == 1 ]]; then document='{"rules":[]}'
  else document="$(policy_document $hosts ${extra[@]+"${extra[@]}"})" || die "Could not read $BOX_BASELINE"; fi
  if [[ "$dry" == 1 ]]; then
    printf 'Sprite: %s\n' "$BOX_NAME"
    print_command "$SPRITE_BIN" create ${SPRITE_ORG[@]+"${SPRITE_ORG[@]}"} --skip-console --label boxen "$BOX_NAME"
    printf 'Agent: %s\n' "$agent"
    printf 'Plugins: %s\n' "${selected:-none}"
    printf 'Privileges: %s\n' "$profile"
    if [[ "$allow_all" == 1 ]]; then printf 'Network: unrestricted (--allow-all)\n'
    else printf 'Network: %s\n' "$(printf '%s' "$document" | jq -r '[.rules[] | .include // .domain] | join(" ")')"; fi
    printf 'Repository: %s\n' "${url:-none (empty /workspace)}"
    printf 'Nothing is uploaded from this machine; the repository is cloned inside the Sprite.\n'
    return
  fi
  need_sprite
  if sprite_exists "$BOX_NAME"; then die "$BOX_NAME already exists (see bxn list); pick another project name."; fi
  if [[ "$gh_stdin" == 1 ]]; then IFS= read -r gh_token || true; fi
  # Keys before the long provisioning run. Blank skips; each stays in this Sprite.
  if terminal; then
    if has_plugin gh-auth && [[ "$gh_stdin" == 0 ]]; then
      printf '\nGitHub: a fine-grained token for the repositories this Sprite needs (Contents read/write,\n'
      printf 'Metadata read-only), with an expiry, from https://github.com/settings/personal-access-tokens/new\n'
      printf 'It is stored inside the Sprite, where the agent and your Fly org can read it.\n'
      read_secret gh_token 'GitHub token (blank to skip): '
    fi
    if has_plugin 1pass; then
      printf '\n1Password: a service account token from https://start.1password.com/settings/automation\n'
      printf 'It is stored inside the Sprite, where the agent can read it.\n'
      read_secret op_token '1Password token (blank to skip): '
    fi
    if [[ "$agent" == grok ]]; then
      printf '\nGrok: an xAI API key from https://console.x.ai. It is stored inside the Sprite.\n'
      read_secret xai_key 'xAI API key (blank to skip): '
    fi
  fi
  log "Creating $BOX_NAME. Agent: $agent; plugins: ${selected:-none}"
  # A Sprite is born unrestricted: lock it down before anything touches it.
  if ! created="$(sprite_cmd create --skip-console --label boxen "$BOX_NAME" </dev/null 2>&1)"; then
    # The CLI has printed failure-like hints for a Sprite it did make.
    if ! sprite_exists "$BOX_NAME"; then
      printf '%s\n' "$created" >&2
      case "$created" in
        *[Ll]imit*|*[Qq]uota*|*[Mm]aximum*|*[Cc]apacity*)
          warn 'Your Fly org may be at its limit of awake Sprites (3 on pay-as-you-go, 10 on the $20 plan).'
          warn 'Sprites sleep about 30 seconds after their last session closes; bxn list --all shows the org'"'"'s.' ;;
      esac
      die "Creating $BOX_NAME failed; nothing was made."
    fi
  fi
  trap unsafe_sprite INT TERM
  if [[ "$allow_all" == 1 ]]; then
    warn "--allow-all: $BOX_NAME has no network policy and can reach any host."
  fi
  log "Applying the network policy and the $profile privileges profile"
  lock_down "$BOX_NAME" "$profile" "$document" || unsafe_sprite
  trap 'build_failed "provisioning (interrupted)"' INT TERM
  log 'Installing the base packages and shell (a few minutes)'
  box_upload_guest || build_failed 'uploading Boxen'"'"'s scripts'
  printf 'export BOXEN_AGENT=%s\nexport BOXEN_PLUGINS=%s\n' "$(sh_quote "$agent")" "$(sh_quote "$selected")" |
    box_root sh -c 'cat > /etc/boxen/sprite.env && chmod 644 /etc/boxen/sprite.env' || build_failed 'recording the agent and plugins'
  box_guest root core-root.sh "$BOX_USER" </dev/null || build_failed 'the base packages'
  box_guest user core-user.sh </dev/null || build_failed 'the shell setup'
  box_guest root workspace.sh </dev/null || build_failed 'making /workspace'
  if [[ "$agent" != shell ]]; then
    log "Checking $agent"
    plugin_run "agent:$agent" </dev/null || build_failed "installing $agent"
  fi
  for item in "${items[@]+"${items[@]}"}"; do
    log "Installing $item"
    plugin_run "$item" </dev/null || build_failed "the $item plugin"
  done
  for identity in name email; do
    value="$(git config --get "user.$identity" 2>/dev/null || true)"
    if [[ -n "$value" ]]; then
      box_user git config --global "user.$identity" "$value" </dev/null || build_failed 'setting the Git identity'
    fi
  done
  # Keys before the clone, which may need the GitHub token.
  if [[ -n "$gh_token" ]]; then
    box_set_env GH_TOKEN "$gh_token" || warn "Storing the GitHub token failed; retry with: bxn auth github $project"
  elif has_plugin gh-auth; then
    printf 'Add a GitHub token later: bxn auth github %s\n' "$project"
  fi
  if [[ -n "$op_token" ]]; then
    box_set_env OP_SERVICE_ACCOUNT_TOKEN "$op_token" || warn "Storing the 1Password token failed; retry with: bxn env $project OP_SERVICE_ACCOUNT_TOKEN"
  elif has_plugin 1pass; then
    printf 'Add a 1Password token later: bxn env %s OP_SERVICE_ACCOUNT_TOKEN\n' "$project"
  fi
  if [[ -n "$xai_key" ]]; then
    box_set_env XAI_API_KEY "$xai_key" || warn "Storing the xAI key failed; retry with: bxn env $project XAI_API_KEY"
  elif [[ "$agent" == grok ]]; then
    printf 'Add an xAI API key later: bxn env %s XAI_API_KEY\n' "$project"
  fi
  gh_token="" op_token="" xai_key=""
  if [[ -n "$url" ]]; then
    log "Cloning $url into /workspace"
    clone_workspace "$url" ||
      warn "Cloning $url failed. A private repository needs a GitHub token: bxn auth github $project. Then retry with: bxn clone $project $url"
  fi
  trap - INT TERM
  # Opening the shell or agent below makes the sign-in offer itself.
  if [[ "$detach" == 1 ]]; then offer_agent_login "$project"; fi
  printf '\n%s is ready. Open a shell with:  bxn %s\n' "$BOX_NAME" "$project"
  if [[ "$agent" != shell ]]; then printf 'Start the agent with:  bxn run %s\n' "$project"; fi
  printf 'It sleeps when idle and wakes on the next command; files persist, processes do not.\n'
  if [[ "$detach" == 0 ]] && terminal; then
    if [[ "$agent" == shell ]]; then cmd_shell "$project"; else cmd_run "$project"; fi
  fi
}

# --- Day to day --------------------------------------------------------------

cmd_shell() {
  local line tty=()
  [[ $# -ge 1 ]] || die 'Usage: shell PROJECT [COMMAND...]'
  need_sprite_named "$1"; shift
  if [[ $# == 0 ]]; then offer_agent_login "$BOX_NAME"; fi
  if terminal; then tty=(--tty); fi
  # One argument is a command line; several are a command and its
  # arguments, quoted so their boundaries survive zsh.
  if [[ $# == 0 ]]; then
    sprite_exec "$BOX_NAME" ${tty[@]+"${tty[@]}"} -- bash "$BOX_GUEST/agent-start.sh" --shell
  elif [[ $# == 1 ]]; then
    sprite_exec "$BOX_NAME" ${tty[@]+"${tty[@]}"} -- bash "$BOX_GUEST/agent-start.sh" --shell "$1"
  else
    printf -v line '%q ' "$@"
    sprite_exec "$BOX_NAME" ${tty[@]+"${tty[@]}"} -- bash "$BOX_GUEST/agent-start.sh" --shell "${line% }"
  fi
}

cmd_run() {
  local tty=()
  [[ $# -ge 1 ]] || die 'Usage: run PROJECT [-- AGENT_ARGS...]'
  need_sprite_named "$1"; shift
  offer_agent_login "$BOX_NAME"
  if [[ "${1:-}" == -- ]]; then shift; fi
  if terminal; then tty=(--tty); fi
  sprite_exec "$BOX_NAME" ${tty[@]+"${tty[@]}"} -- bash "$BOX_GUEST/agent-start.sh" "$@"
}

cmd_exec() {
  local tty=()
  [[ $# -ge 2 ]] || die 'Usage: exec PROJECT COMMAND [ARGS...]'
  need_sprite_named "$1"; shift
  if terminal; then tty=(--tty); fi
  sprite_exec "$BOX_NAME" ${tty[@]+"${tty[@]}"} -- "$@"
}

cmd_clone() {
  local url
  [[ $# == 1 || $# == 2 ]] || die 'Usage: clone PROJECT [REPO]'
  url="$(clone_url "${2:-}")" || exit 1
  need_sprite_named "$1"
  log "Cloning $url into /workspace"
  clone_workspace "$url" ||
    die "Cloning $url failed. A private repository needs a GitHub token: bxn auth github $1"
}

cmd_list() {
  need_sprite
  case "${1:-}" in
    --all) sprite_cmd list </dev/null ;;
    '') ensure_handle; sprite_cmd list --prefix "$HANDLE-" </dev/null ;;
    *) die 'Usage: list [--all]' ;;
  esac
}

# confirm PROMPT YES: true when YES is 1, or a terminal answers y.
confirm() {
  local answer
  [[ "$2" != 1 ]] || return 0
  terminal || die "$1 needs a terminal to confirm, or --yes."
  read_value answer "$1 [y/N] "
  case "$answer" in y|Y|yes|Yes|YES) return 0 ;; esac
  return 1
}

cmd_delete() {
  local yes=0 project=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) yes=1 ;;
      -*) die "Unknown delete option: $1" ;;
      *) [[ -z "$project" ]] || die 'Usage: delete PROJECT [--yes] (one Sprite at a time)'; project="$1" ;;
    esac
    shift
  done
  [[ -n "$project" ]] || die 'Usage: delete PROJECT [--yes]'
  need_sprite_named "$project"
  confirm "Destroy $BOX_NAME and everything in it, checkpoints included?" "$yes" || die 'Nothing was deleted.'
  sprite_cmd destroy --force "$BOX_NAME" </dev/null
  if sprite_exists "$BOX_NAME"; then die "$BOX_NAME was not deleted"; fi
  log "Deleted $BOX_NAME"
}

cmd_allow() {
  local host current document hosts=()
  [[ $# -ge 2 ]] || die 'Usage: allow PROJECT HOST...'
  need_sprite_named "$1"; shift
  for host in "$@"; do
    host="$(lower "$host")"
    valid_host "$host" || die "Not a host name: $host (use example.com or *.example.com)"
    hosts+=("$host")
  done
  need_jq
  # Read, merge, post the whole document: never a blind append.
  current="$(policy_get "$BOX_NAME")" || die "Could not read $BOX_NAME's network policy"
  if [[ "$(printf '%s' "$current" | jq '.rules // [] | length')" == 0 ]]; then
    die "$BOX_NAME has no network policy (it can reach any host already); nothing to allow."
  fi
  document="$(printf '%s' "$current" | policy_merge "${hosts[@]}")" || die 'Could not merge the policy'
  printf '%s' "$document" | policy_set "$BOX_NAME" || die "Could not set $BOX_NAME's network policy"
  policy_enforced "$BOX_NAME" "$document" ||
    die "The policy was sent, but $BOX_NAME does not report it yet; check with bxn policy $BOX_NAME"
  log "Allowed ${hosts[*]} in $BOX_NAME"
}

cmd_policy() {
  [[ $# == 1 ]] || die 'Usage: policy PROJECT'
  need_sprite_named "$1"
  need_jq
  printf 'Network policy:\n'
  policy_get "$BOX_NAME" | jq .
  printf 'Privileges: %s\n' "$(privileges_get "$BOX_NAME")"
}

cmd_env() {
  local value re='^[A-Za-z_][A-Za-z0-9_]*$'
  [[ $# == 2 ]] || die 'Usage: env PROJECT VAR_NAME'
  [[ "$2" =~ $re ]] || die "Invalid variable name: $2"
  need_sprite_named "$1"
  if [[ -t 0 ]]; then
    read_secret value "Enter value for $2 (input hidden, paste ok): "
  else
    IFS= read -r value || true
  fi
  [[ -n "$value" ]] || die 'Value required'
  box_set_env "$2" "$value"
  log "Set $2 in $BOX_NAME. Its shells and agent see it; so can anyone in your Fly org."
}

cmd_auth() {
  local token
  [[ $# == 2 && "$1" == github ]] || die 'Usage: auth github PROJECT'
  need_sprite_named "$2"
  if [[ -t 0 ]]; then
    printf 'Create a fine-grained token at https://github.com/settings/personal-access-tokens/new\n' >&2
    printf 'Recommended: only the repositories this Sprite needs, Contents read/write, Metadata\n' >&2
    printf 'read-only, and an expiry.\n' >&2
    read_secret token 'GitHub token: '
  else
    IFS= read -r token || true
  fi
  [[ -n "$token" ]] || die 'GitHub token required'
  box_set_env GH_TOKEN "$token"
  token=""
  box_guest user gh-auth.sh </dev/null || warn 'Pointing Git at gh failed; git may still ask for a password.'
  log "Stored the GitHub token in $BOX_NAME"
}

cmd_checkpoint() {
  local comment=()
  [[ $# == 1 || $# == 2 ]] || die 'Usage: checkpoint PROJECT [COMMENT]'
  need_sprite_named "$1"
  if [[ $# == 2 ]]; then comment=(--comment "$2"); fi
  sprite_cmd 'checkpoint create' -s "$BOX_NAME" ${comment[@]+"${comment[@]}"} </dev/null
}

cmd_checkpoints() {
  [[ $# == 1 ]] || die 'Usage: checkpoints PROJECT'
  need_sprite_named "$1"
  sprite_cmd 'checkpoint list' -s "$BOX_NAME" </dev/null
}

cmd_restore() {
  local yes=0 args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in --yes|-y) yes=1 ;; *) args+=("$1") ;; esac
    shift
  done
  [[ ${#args[@]} == 2 ]] || die 'Usage: restore PROJECT CHECKPOINT [--yes]'
  need_sprite_named "${args[0]}"
  printf 'Restoring replaces the whole filesystem: everything since %s is lost.\n' "${args[1]}" >&2
  printf 'bxn checkpoint %s first keeps a way back.\n' "${args[0]}" >&2
  confirm "Restore $BOX_NAME to ${args[1]}?" "$yes" || die 'Nothing was restored.'
  sprite_cmd restore -s "$BOX_NAME" "${args[1]}" </dev/null
}

# The repo's supabase/config.toml, from /workspace or one folder down, or
# nothing.
supabase_config() {
  sprite_exec "$1" --no-port-forward -- sh -c \
    'for f in /workspace/supabase/config.toml /workspace/*/supabase/config.toml; do
       if [ -f "$f" ]; then cat "$f"; exit 0; fi
     done' </dev/null 2>/dev/null || true
}
# supabase_ports CONFIG: "api PORT", "db PORT", "studio PORT" and
# "inbucket PORT" lines, from the config's sections or Supabase's defaults.
supabase_ports() {
  printf '%s\n' "$1" | awk -v defaults="$SUPABASE_DEFAULTS" '
    BEGIN {
      n = split(defaults, d, " ")
      for (i = 1; i <= n; i++) { split(d[i], kv, "="); order[i] = kv[1]; port[kv[1]] = kv[2] }
    }
    /^[[:space:]]*\[/ { section = $0; gsub(/[][[:space:]]/, "", section); next }
    (section in port) && /^[[:space:]]*port[[:space:]]*=/ {
      v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[^0-9].*$/, "", v)
      if (v != "") port[section] = v
    }
    END { for (i = 1; i <= n; i++) print order[i], port[order[i]] }'
}
# sprite_listening NAME PORT...: the ports something listens on in the Sprite.
sprite_listening() {
  local name="$1"
  shift
  sprite_exec "$name" --no-port-forward -- bash -c \
    'for p in "$@"; do if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then echo "$p"; fi; done' \
    bash "$@" </dev/null 2>/dev/null || true
}
# Something on this machine already listens on the port.
local_port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# supabase_plan NAME: the Supabase stack's ports in SUPABASE_FORWARD, and a
# link for each in SUPABASE_LINKS, marked when nothing listens on it yet.
supabase_plan() {
  local name="$1" config key port api="" db="" studio="" mail="" up line label url
  config="$(supabase_config "$name")"
  [[ -n "$config" ]] || warn "No supabase/config.toml in /workspace; using Supabase's default ports."
  while read -r key port; do
    case "$key" in
      api) api="$port" ;; db) db="$port" ;; studio) studio="$port" ;; inbucket) mail="$port" ;;
    esac
  done <<EOF_PORTS
$(supabase_ports "$config")
EOF_PORTS
  SUPABASE_FORWARD="$studio $mail $api $db $SUPABASE_APP_PORT"
  # shellcheck disable=SC2086 # one argument per port
  up=" $(sprite_listening "$name" $SUPABASE_FORWARD | tr '\n' ' ') "
  in_list "$api" "$up" || in_list "$studio" "$up" || in_list "$db" "$up" ||
    warn "Supabase is not running in $name yet: run supabase start in bxn shell, and these links work once it is up."
  SUPABASE_LINKS=""
  for line in "Studio $studio http://localhost:$studio" "Mailpit $mail http://localhost:$mail" \
              "API $api http://localhost:$api" "App $SUPABASE_APP_PORT http://localhost:$SUPABASE_APP_PORT" \
              "Database $db postgresql://postgres:postgres@localhost:$db/postgres"; do
    label="${line%% *}"; line="${line#* }"; port="${line%% *}"; url="${line#* }"
    line="$(printf '  %-9s %s' "$label" "$url")"
    in_list "$port" "$up" || line="$line   (not running)"
    SUPABASE_LINKS="$SUPABASE_LINKS$line
"
  done
}

cmd_proxy() {
  local port ports=() re='^[0-9]{1,5}(:[0-9]{1,5})?$' supabase=0
  [[ $# -ge 2 ]] || die 'Usage: proxy PROJECT PORT|LOCAL:REMOTE...|supabase'
  need_sprite_named "$1"; shift
  for port in "$@"; do
    if [[ "$port" == supabase ]]; then supabase=1; continue; fi
    [[ "$port" =~ $re ]] || die "Expected PORT or LOCAL:REMOTE, got $port"
    ports+=("$port")
  done
  if [[ "$supabase" == 1 ]]; then
    supabase_plan "$BOX_NAME"
    # shellcheck disable=SC2206 # one element per port
    ports+=($SUPABASE_FORWARD)
  fi
  # Studio links to the API by its port, so ports keep their numbers rather
  # than moving to free ones.
  for port in "${ports[@]}"; do
    if local_port_busy "${port%%:*}"; then
      [[ "$supabase" == 1 ]] && die "localhost:${port%%:*} is in use on this machine. A local Supabase? Stop it with supabase stop."
      die "localhost:${port%%:*} is in use on this machine; forward to another with LOCAL:REMOTE."
    fi
  done
  [[ "$supabase" == 0 ]] || printf 'Supabase in %s, on this machine while this runs:\n%s' "$BOX_NAME" "$SUPABASE_LINKS"
  log "Forwarding ${ports[*]} to localhost on this machine; Ctrl-C stops."
  sprite_cmd proxy -s "$BOX_NAME" "${ports[@]}"
}

cmd_url() {
  local info
  [[ $# == 1 ]] || die 'Usage: url PROJECT'
  need_sprite_named "$1"
  need_jq
  # sprite url is deprecated; the Sprite's record holds the URL and who may open it.
  info="$(sprite_api "$BOX_NAME" / </dev/null)" || die "Could not read $BOX_NAME from the Sprites API"
  printf '%s' "$info" | jq -r '(.data // .) | .url, "Access: \(.url_settings.auth // "?"), private access for \(.url_settings.private_access // "?")"' ||
    die "Could not read $BOX_NAME's URL"
  printf 'The URL reaches port 8080 and needs a Fly login from your org. bxn never makes it public.\n'
}

cmd_check() {
  [[ $# == 1 ]] || die 'Usage: check PROJECT'
  need_sprite_named "$1"
  GUEST_TTY=()
  guest_script check.sh </dev/null
}

cmd_plugins() {
  awk -F'\t' 'NR > 1 { printf "%-15s %-8s %s\n", $1, ($2 == "yes" ? "default" : ""), $3 }' "$PLUGIN_INDEX"
}

cmd_handle() {
  local old
  case $# in
    0) handle ;;
    1)
      valid_handle "$1" || die "Invalid handle: $1. Use 1-20 lowercase letters, digits and hyphens."
      mkdir -p "$CONFIG_DIR"
      # Remember the old handle so its Sprites stay reachable by full name.
      if [[ -f "$HANDLE_FILE" ]]; then
        old="$(head -1 "$HANDLE_FILE")"
        if [[ "$old" != "$1" ]] && valid_handle "$old" &&
          ! grep -Fxq -- "$old" "$FORMER_HANDLES_FILE" 2>/dev/null; then
          printf '%s\n' "$old" >> "$FORMER_HANDLES_FILE"
        fi
      fi
      printf '%s\n' "$1" > "$HANDLE_FILE"
      log "Your Sprites are now named $1-PROJECT. Existing Sprites keep their names; reach them by full name."
      ;;
    *) die 'Usage: handle [NEW]' ;;
  esac
}

cmd_doctor() {
  local failed=0
  [[ $# == 0 ]] || die 'Usage: doctor'
  need_sprite
  printf 'sprite: %s\n' "$SPRITE_PATH"
  if sprite_cmd org list </dev/null >/dev/null 2>&1; then printf 'Logged in: yes\n'
  else printf 'Logged in: no (run sprite login)\n'; failed=1; fi
  if command -v jq >/dev/null 2>&1; then printf 'jq: ok\n'
  else printf 'jq: missing (create, allow and policy need it)\n'; failed=1; fi
  if [[ -n "${BOXEN_SPRITE_ORG:-}" ]]; then printf 'Organization: %s (BOXEN_SPRITE_ORG)\n' "$BOXEN_SPRITE_ORG"; fi
  if [[ -f "$HANDLE_FILE" ]]; then printf 'Handle: %s\n' "$(head -1 "$HANDLE_FILE")"
  else printf 'Handle: not chosen yet; create asks (default: %s)\n' "$(default_handle)"; fi
  [[ "$failed" == 0 ]] || exit 1
}

main() {
  local command="${1:-help}"
  if [[ $# != 0 ]]; then shift; fi
  case "$command" in
    help|-h|--help) usage ;;
    plugins) cmd_plugins ;;
    create|init|-i) create "$@" ;;
    shell|-s) cmd_shell "$@" ;;
    run) cmd_run "$@" ;;
    exec) cmd_exec "$@" ;;
    clone) cmd_clone "$@" ;;
    list|ls) cmd_list "$@" ;;
    delete|destroy|-d) cmd_delete "$@" ;;
    allow) cmd_allow "$@" ;;
    policy) cmd_policy "$@" ;;
    env|-e) cmd_env "$@" ;;
    auth) cmd_auth "$@" ;;
    checkpoint) cmd_checkpoint "$@" ;;
    checkpoints) cmd_checkpoints "$@" ;;
    restore) cmd_restore "$@" ;;
    proxy) cmd_proxy "$@" ;;
    url) cmd_url "$@" ;;
    check) cmd_check "$@" ;;
    handle) cmd_handle "$@" ;;
    doctor) cmd_doctor "$@" ;;
    stop|kill|-k|kill-all|-ka) die 'Sprites sleep by themselves about 30 seconds after their last session closes.' ;;
    update|-u|update-all|-ua|cron) die 'Run apt as root in the Sprite instead: bxn exec PROJECT sudo apt-get upgrade' ;;
    net|-n) die 'Use bxn proxy PROJECT PORT.' ;;
    tailscale) die 'Tailscale is gone: use bxn proxy PROJECT PORT, or the Sprite'"'"'s private URL (bxn url).' ;;
    status) cmd_list ;;
    -*) die "Unknown option: $command (try --help)" ;;
    # A bare name opens a shell.
    *) cmd_shell "$command" "$@" ;;
  esac
}
