# Sourced by agbx. Credentials are never accepted as command arguments.
# Bash 3.2: no associative arrays; guard empty arrays under set -u.

# Optional kits in install order. Docker is native to every sandbox, so there
# is nothing to choose.
KITS="fzf-bat just glow mermaid-ascii overmind cubic chromium nvchad rtkplus tailscale supabase-serve gh-auth 1pass"
PLUGINS="$KITS"
# No kit is selected by default.
DEFAULT_PLUGINS=""
AGENTS="shell claude codex grok"
# env variables that sbx can inject through its proxy instead of the guest.
SERVICE_VARS="ANTHROPIC_API_KEY:anthropic OPENAI_API_KEY:openai XAI_API_KEY:xai GH_TOKEN:github GITHUB_TOKEN:github GROQ_API_KEY:groq MISTRAL_API_KEY:mistral OPENROUTER_API_KEY:openrouter GEMINI_API_KEY:google GOOGLE_API_KEY:google"
MIN_SBX_VERSION=0.47.0
STATE_DIR="${AGBX_STATE_DIR:-$HOME/.local/state/agbx}"
REGISTRY="$STATE_DIR/sandboxes"
LOG_DIR="$STATE_DIR/logs"
CRON_TAG="# agbx-update-all"
UPDATE_SCRIPT='export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get upgrade -y'

die() { printf 'agbx: %s\n' "$*" >&2; exit 1; }
log() { printf '[+] %s\n' "$*"; }
warn() { printf 'agbx: %s\n' "$*" >&2; }
# Call sbx by the path need_sbx resolved. Not `command sbx`: in Bash 3.2 a
# failing `command` inside a function exits under set -e even within ||.
SBX_PATH=""
sbx() { "$SBX_PATH" "$@"; }
need_sbx() {
  SBX_PATH="$(type -P "$SBX_BIN")" || die 'Install sbx and run sbx login first; see README.md.'
}
need_jq() { command -v jq >/dev/null 2>&1 || die "Install jq; $1 reads sbx ls --json."; }
need_value() { [[ $# -ge 2 && -n "$2" ]] || die "Missing value for $1"; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
valid_name() {
  local re='^[a-zA-Z0-9][a-zA-Z0-9-]+$'
  [[ "$1" =~ $re && ${#1} -le 63 && "$1" != default ]] ||
    die "Invalid name: $1. Use 2-63 letters, digits and hyphens; 'default' is reserved."
}
has_plugin() { [[ ",$selected," == *",$1,"* ]]; }
add_plugin() { has_plugin "$1" || selected="${selected:+$selected,}$1"; }
set_agent() {
  [[ -z "$agent" || "$agent" == "$1" ]] ||
    die "One agent per sandbox: got $agent and $1. Create a second sandbox for the other agent."
  agent="$1"
}

usage() {
  cat <<'EOF'
agbx create NAME [DIRECTORY] [options]      (also: init, -i)
  -p, --path DIR                 Host directory to copy (default: current directory)
  --no-copy                      Start with an empty /workspace
  --mode copy|mount|clone|none   copy (default), bind mount, sbx Git clone, or empty;
                                 only mount and clone share the host directory
  --skills off|readonly|readwrite
                                 Share the host's sbx skills store. Default: off
  --agent shell|claude|codex|grok
                                 One per sandbox. Default: shell
  --plugins default|all|none|ID,ID,...
                                 Default: none
  --tailscale --supabase-serve --gh-token --1pass --cubic
  --claude --codex --grok        Shorthand flags; added to the selection
  --cpus N --memory SIZE         Default: 4 CPUs (at most the host's), 4g
  --ack-env                      Copy .env files without asking
  --copy-all                     Also copy node_modules, deps, _build and other
                                 folders the sandbox rebuilds
  --no-tui                       Skip the interactive selector; use flags and defaults
  --dry-run                      Print the creation plan without creating

agbx NAME                                   Open zsh in the sandbox
agbx shell [--with-sudo] NAME [COMMAND...]  (also: -s) --with-sudo grants
                                            sudo for this session only
agbx run NAME [-- ARGS...]                  Attach to its agent
agbx exec NAME COMMAND [ARGS...]            Run a command
agbx net NAME [-b ADDR|-H HOST] [-l] [-r PORT] [PORT|HOST:SANDBOX ...]
                                            (also: -n) Publish ports on the host
agbx env NAME VAR                           (also: -e) Set a variable; prompts silently
agbx stop NAME                              (also: kill, -k)
agbx kill-all                               (also: -ka) Stop all agbx sandboxes
agbx delete NAME                            (also: -d) sbx asks to confirm
agbx update NAME                            (also: -u) apt-get upgrade as root
agbx update-all                             (also: -ua)
agbx cron install [HOUR]|remove|status      Nightly update-all (default 19:00)
agbx status [--once]                        sbx's dashboard, or its table once
agbx ls                                     List sandboxes
agbx check NAME                             Check installed plugins
agbx plugins                                List the plugins and what they install
agbx validate                               Validate all kits using the installed sbx
agbx doctor                                 Check local prerequisites

agbx auth github NAME [--from-gh]           Store a fine-grained token (stdin or
                                            prompt), or source the host gh token
agbx auth 1password NAME SERVICE OP_REFERENCE
                                            Source a credential from host op
agbx tailscale join NAME [--auth-key-stdin]
agbx tailscale status NAME
agbx tailscale serve NAME PORT|supabase     Publish HTTPS :443 or the seven preset routes

Commands that take NAME never create a sandbox; only create does.
EOF
}

# --- Sandboxes ---------------------------------------------------------------

sandbox_exists() {
  local names
  names="$(sbx ls --quiet)" || die 'sbx ls failed; check agbx doctor.'
  printf '%s\n' "$names" | grep -Fxq -- "$1"
}
# Every command that takes NAME checks first, so a typo can never reach a
# command such as sbx run that creates a missing sandbox.
need_sandbox() {
  valid_name "$1"
  need_sbx
  sandbox_exists "$1" ||
    die "No sandbox named $1 (see agbx ls). Nothing was created; use agbx create $1."
}
register() {
  mkdir -p "$STATE_DIR"
  grep -Fxq -- "$1" "$REGISTRY" 2>/dev/null || printf '%s\n' "$1" >> "$REGISTRY"
}
unregister() {
  [[ -f "$REGISTRY" ]] || return 0
  grep -Fxv -- "$1" "$REGISTRY" > "$REGISTRY.tmp" || true
  mv "$REGISTRY.tmp" "$REGISTRY"
}
# "NAME STATUS" for each sandbox agbx created that still exists.
managed_states() {
  need_jq "$1"
  [[ -s "$REGISTRY" ]] || return 0
  sbx ls --json </dev/null | jq -r --arg registry "$(cat "$REGISTRY")" '
    ($registry | split("\n") | map(select(length > 0))) as $names
    | .sandboxes[]? | select(.name as $n | $names | index($n)) | "\(.name) \(.status)"'
}

# --- Resources ---------------------------------------------------------------

host_cpus() {
  local n
  n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] || n=1
  printf '%s\n' "$n"
}
# Binary units as sbx takes them (512m, 4g); a bare number is bytes.
to_kib() {
  local re='^([0-9]+)([kKmMgGtT]?)([iI]?[bB]?)$' n
  [[ "$1" =~ $re ]] || return 1
  n="${BASH_REMATCH[1]}"
  case "${BASH_REMATCH[2]}" in
    '') echo $((n / 1024)) ;;
    k|K) echo "$n" ;;
    m|M) echo $((n * 1024)) ;;
    g|G) echo $((n * 1024 * 1024)) ;;
    t|T) echo $((n * 1024 * 1024 * 1024)) ;;
  esac
}
# Linux only. Starting a microVM the host cannot hold lets the OOM killer
# take other processes, as happened during validation.
memory_ok() {
  local meminfo="${AGBX_MEMINFO:-/proc/meminfo}" need avail
  [[ "${AGBX_SKIP_MEMORY_CHECK:-0}" != 1 && -r "$meminfo" ]] || return 0
  need="$(to_kib "$1")" || die "Invalid memory size: $1"
  avail="$(awk '/^MemAvailable:/ {print $2}' "$meminfo")"
  [[ -n "$avail" ]] || return 0
  if (( avail < need + 1048576 )); then
    printf 'agbx: Only %s MiB of memory is available; a %s sandbox needs %s MiB plus 1024 MiB headroom.\n' \
      "$((avail / 1024))" "$1" "$((need / 1024))" >&2
    printf 'Stop another sandbox or pass a smaller --memory. AGBX_SKIP_MEMORY_CHECK=1 skips this check.\n' >&2
    return 1
  fi
}

# --- Workspace ---------------------------------------------------------------

env_files() {
  find "$1" \
    \( -type d \( -name node_modules -o -name .git -o -name vendor -o -name target \
       -o -name dist -o -name build \) -prune \) -o \
    \( -type f -name '.env*' ! -name .env.example ! -name .env.sample \
       ! -name .env.template ! -name .env.dist -print \)
}
# DIRECTORY ACK DRY: the sandbox and its agent can read every copied file.
confirm_env_files() {
  local found file answer
  found="$(env_files "$1")"
  [[ -n "$found" && "$2" != 1 ]] || return 0
  printf 'These files may hold secrets, and the sandbox and its agent could read them:\n' >&2
  while IFS= read -r file; do printf '  %s\n' "${file#"$1"/}" >&2; done <<< "$found"
  [[ "$3" != 1 ]] || return 0
  if [[ -t 0 ]]; then
    read_value answer 'Copy them anyway? [y/N] '
    case "$answer" in y|Y|yes|Yes|YES) return 0 ;; esac
  fi
  die 'Stopped before creating anything. Remove the files, or pass --ack-env to include them.'
}
# Dependency and build folders the sandbox rebuilds for itself, as ./ paths.
# They are most of a copy's bytes, and host builds are often the wrong
# platform for Linux. Folders with generic names count only beside the file
# that makes them a build folder.
copy_skips() {
  local dir="$1" path
  while IFS= read -r path; do
    [[ -n "$path" && "$path" != "$dir" ]] || continue
    case "${path##*/}" in
      _build|deps|.elixir_ls|.lexical) [[ -f "${path%/*}/mix.exs" ]] || continue ;;
      target) [[ -f "${path%/*}/Cargo.toml" ]] || continue ;;
      .venv|venv) [[ -f "$path/pyvenv.cfg" ]] || continue ;;
    esac
    printf './%s\n' "${path#"$dir"/}"
  done < <(find "$dir" -name .git -prune -o -type d \( -name node_modules -o -name _build \
      -o -name deps -o -name .elixir_ls -o -name .lexical -o -name target -o -name .venv \
      -o -name venv -o -name __pycache__ -o -name .pytest_cache -o -name .mypy_cache \
      -o -name .ruff_cache -o -name .next -o -name .nuxt -o -name .svelte-kit -o -name .turbo \
      -o -name .parcel-cache \) -prune -print)
}
# Total KiB of the given paths.
size_kib() { du -sk "$@" 2>/dev/null | awk '{ s += $1 } END { print s + 0 }'; }
human_kib() {
  awk -v k="$1" 'BEGIN { if (k >= 1048576) printf "%.1f GiB", k / 1048576
    else if (k >= 1024) printf "%.0f MiB", k / 1024; else printf "%d KiB", k }'
}
# A progress bar when pv is installed; otherwise the stream passes through.
meter() {
  if [[ -t 2 ]] && command -v pv >/dev/null 2>&1; then pv -s "$1"; else cat; fi
}
# DIRECTORY SKIPS: KiB the copy will send.
copy_size() {
  local skip total skipped=0 paths=()
  total="$(size_kib "$1")"
  while IFS= read -r skip; do
    if [[ -n "$skip" ]]; then paths+=("$1/${skip#./}"); fi
  done <<< "$2"
  if [[ ${#paths[@]} -gt 0 ]]; then skipped="$(size_kib "${paths[@]}")"; fi
  if (( total > skipped )); then echo $((total - skipped)); else echo 0; fi
}
# KIB SKIPS
copy_summary() {
  local skip count=0
  printf 'Copy: about %s\n' "$(human_kib "$1")"
  [[ -n "$2" ]] || return 0
  printf 'Skipping folders the sandbox rebuilds (--copy-all copies them):\n'
  while IFS= read -r skip; do
    count=$((count + 1))
    if (( count <= 10 )); then printf '  %s\n' "${skip#./}"; fi
  done <<< "$2"
  if (( count > 10 )); then printf '  and %d more\n' "$((count - 10))"; fi
}
# NAME DIRECTORY SKIPS BYTES
copy_workspace() {
  local name="$1" directory="$2" skip prune=() mac=()
  while IFS= read -r skip; do
    [[ -n "$skip" ]] || continue
    if [[ ${#prune[@]} -gt 0 ]]; then prune+=(-o); fi
    prune+=(-path "$skip")
  done <<< "$(printf '%s\n' "$3" | sed 's/[][*?\\]/\\&/g')" # literal, not glob
  if [[ ${#prune[@]} -gt 0 ]]; then prune=('(' "${prune[@]}" ')' -prune -o); fi
  if tar --version 2>/dev/null | grep -q bsdtar; then
    # macOS: no AppleDouble ._ files, resource forks or extended attributes.
    mac=(--no-mac-metadata --no-xattrs)
  fi
  # find names every path to send: tar's own --exclude matches nested
  # folders of the same name on macOS, so tools/deps would vanish with ./deps.
  (cd "$directory" && find . ${prune[@]+"${prune[@]}"} -print0) |
    COPYFILE_DISABLE=1 tar -cf - ${mac[@]+"${mac[@]}"} -C "$directory" --null --no-recursion -T - |
    meter "$4" |
    sbx exec -i --workdir /home/agent/workspace "$name" \
      tar --no-same-owner --warning=no-unknown-keyword -xf -
}
created_but() {
  printf 'agbx: Sandbox %s was created, but %s failed.\n' "$1" "$2" >&2
  printf 'Look inside with: agbx shell %s\n' "$1" >&2
  printf 'To start over: sbx rm %s, then run create again.\n' "$1" >&2
  exit 1
}

# --- Credentials -------------------------------------------------------------

# A host-wide sbx secret for SERVICE is injected into every sandbox.
host_wide_secret() {
  local listing
  listing="$(sbx secret ls --global --service "$1" --json 2>/dev/null)" || return 1
  [[ -n "$listing" && "$(printf '%s' "$listing" | tr -d ' \t\n')" != *'"secrets":[]'* ]]
}
# Docker's Claude and Codex workloads prefer a host-wide secret, which then
# takes the place of each sandbox's own subscription sign-in.
warn_host_wide_agent_secret() {
  local service
  case "$1" in claude) service=anthropic ;; codex) service=openai ;; *) return 0 ;; esac
  if host_wide_secret "$service"; then
    warn "sbx has a host-wide $service secret, so this sandbox uses it instead of its own sign-in. Remove it with: sbx secret rm $service"
  fi
}
# Offer the agent's subscription sign-in on the way in, when the sandbox needs
# one. Terminal only; anything unexpected skips the offer instead of blocking.
offer_agent_login() {
  local status=0 answer
  [[ -t 0 && -t 1 ]] || return 0
  sbx exec "$1" bash /home/agent/.local/share/agbx/agent-login.sh status </dev/null >/dev/null 2>&1 || status=$?
  [[ "$status" == 10 ]] || return 0
  read_value answer "$1's agent is not signed in. Sign in to your subscription now? [Y/n] "
  case "$answer" in n|N|no|No|NO) return 0 ;; esac
  sbx exec -it "$1" bash /home/agent/.local/share/agbx/agent-login.sh login ||
    warn "Sign-in did not finish; agbx $1 offers it again."
}
# Reads `export VAR=value` on stdin and stores it in the sandbox, replacing any
# earlier value. The sandbox and its agent can read it.
write_guest_env() {
  sbx exec -i "$1" sh -c '
    umask 077
    dir="$HOME/.config/agbx"; file="$dir/env.sh"
    mkdir -p "$dir"; touch "$file"
    grep -v "^export $1=" "$file" > "$file.tmp" || true
    cat >> "$file.tmp"
    mv "$file.tmp" "$file"' sh "$2"
}

# --- Commands ----------------------------------------------------------------

create() {
  local name="" directory="" agent="" requested="$DEFAULT_PLUGINS" flagged="" mode=""
  local dry=0 ack_env=0 memory="${AGBX_MEMORY:-4g}" cpus="${AGBX_CPUS:-}"
  local copy_all=0 skips="" copy_kib=0
  # Nothing from the host is mounted unless asked: no workspace mount, no
  # shared skills store (sbx's own default is a read-only link).
  local skills=off mounts="" tui=1 chose_plugins=0
  local gh_token="" op_token="" ts_key="" ts_port="" port_re='^[0-9]+$'
  local selected="" item kit workload identity value home
  local kit_args=() command=() items=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent) need_value "$@"; set_agent "$2"; shift 2 ;;
      --claude|--claude-code) set_agent claude; shift ;;
      --codex) set_agent codex; shift ;;
      --grok|--grokbot) set_agent grok; shift ;;
      --plugins) need_value "$@"; requested="$2"; chose_plugins=1; shift 2 ;;
      --docker) shift ;; # Always included
      --cubic|--tailscale|--supabase-serve|--1pass)
        flagged="${flagged:+$flagged,}${1#--}"; shift ;;
      --gh-token) flagged="${flagged:+$flagged,}gh-auth"; shift ;;
      -p|--path)
        need_value "$@"
        [[ -z "$directory" ]] || die 'Only one workspace directory is supported'
        directory="$2"; shift 2 ;;
      --no-copy) mode=none; shift ;;
      --mode) need_value "$@"; mode="$2"; shift 2 ;;
      --skills)
        need_value "$@"
        case "$2" in off|readonly|readwrite) skills="$2" ;; *) die "Unknown --skills mode: $2 (off, readonly or readwrite)" ;; esac
        shift 2 ;;
      -w|--workspace)
        need_value "$@"
        case "$2" in
          /workspace|/workspace/|/home/agent/workspace) ;;
          copy|mount|clone|none) die "--workspace is the path inside the sandbox. Use --mode $2." ;;
          *) die "The workspace is always /workspace (linked to /home/agent/workspace); --workspace $2 is not supported." ;;
        esac
        shift 2 ;;
      --cpus) need_value "$@"; cpus="$2"; shift 2 ;;
      --memory) need_value "$@"; memory="$2"; shift 2 ;;
      --ack-env) ack_env=1; shift ;;
      --copy-all) copy_all=1; shift ;;
      --no-tui) tui=0; shift ;;
      --dry-run) dry=1; shift ;;
      -f|--from|-t|--template) die 'Templates are not supported: a template could carry a Tailscale identity.' ;;
      -i|--image) die '--image is not supported; sbx chooses the image for each agent.' ;;
      --vm|--vm-disk|--vm-memory|--vm-cpus) die 'Every sbx sandbox is a microVM; size it with --memory and --cpus.' ;;
      --colima-cpus|--colima-memory|--colima-disk) die 'Colima is not used; sbx runs its own VMs.' ;;
      -h|--help) usage; return ;;
      -*) die "Unknown create option: $1" ;;
      *)
        if [[ -z "$name" ]]; then name="$1"
        elif [[ -z "$directory" ]]; then directory="$1"
        else die 'Only one workspace directory is supported'; fi
        shift ;;
    esac
  done
  [[ -n "$name" ]] || die 'create requires a name'
  valid_name "$name"
  agent="${agent:-shell}"
  in_list "$agent" "$AGENTS" || die "Unknown agent: $agent"
  if [[ "$mode" == none ]]; then
    [[ -z "$directory" ]] || die 'Do not supply a directory with --no-copy or --mode none'
  else
    mode="${mode:-copy}"
    directory="${directory:-$PWD}"
    [[ -d "$directory" ]] || die "Not a directory: $directory"
    directory="$(cd "$directory" && pwd -P)"
    home="$(cd "$HOME" 2>/dev/null && pwd -P || true)"
    [[ "$directory" != / && "$directory" != "$home" ]] ||
      die "Refusing to share $directory; choose a project directory with -p, or pass --no-copy."
  fi
  case "$mode" in copy|mount|clone|none) ;; *) die "Unknown mode: $mode (copy, mount, clone or none)" ;; esac
  if [[ "$mode" == clone ]]; then
    git -C "$directory" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
      die 'clone requires a Git worktree'
  fi
  case "$requested" in
    default) requested="$DEFAULT_PLUGINS" ;;
    all) requested="${PLUGINS// /,}" ;;
    none) requested="" ;;
  esac
  IFS=, read -r -a items <<< "${requested}${flagged:+,$flagged}"
  for item in "${items[@]+"${items[@]}"}"; do
    case "$item" in
      ''|docker) continue ;; # Docker is always included
      chadmux) die 'Chadmux/tmux integration is intentionally excluded.' ;;
      claude-code|codex|grok) die "Select the agent with --agent (one per sandbox), not --plugins $item." ;;
    esac
    in_list "$item" "$PLUGINS" || die "Unknown plugin: $item (see agbx plugins)"
    add_plugin "$item"
  done
  # The selector shows in a terminal unless --plugins already chose the kits.
  if [[ "$tui" == 1 && "$chose_plugins" == 0 && -t 0 && -t 1 ]]; then tui_select; fi
  if has_plugin supabase-serve; then add_plugin tailscale; fi
  if [[ -z "$cpus" ]]; then
    cpus="$(host_cpus)"
    if [[ "$cpus" -gt 4 ]]; then cpus=4; fi
  fi
  [[ "$cpus" =~ ^[1-9][0-9]*$ ]] || die "Invalid --cpus: $cpus"
  to_kib "$memory" >/dev/null || die "Invalid --memory: $memory (for example 2g or 512m)"

  kit_args=(--kit "$PROJECT_DIR/kits/core")
  # Copied and empty workspaces live on a kit volume so they survive
  # container recreation, such as sbx kit add.
  case "$mode" in copy|none) kit_args+=(--kit "$PROJECT_DIR/kits/workspace") ;; esac
  for kit in $KITS; do
    if has_plugin "$kit"; then kit_args+=(--kit "$PROJECT_DIR/kits/$kit"); fi
  done
  workload="$agent"
  if [[ "$agent" == grok ]]; then workload="$PROJECT_DIR/agents/grok"; fi
  if [[ "$agent" == claude ]] && has_plugin rtkplus; then
    workload="$PROJECT_DIR/agents/claude-rtk"
  fi
  case "$mode" in
    mount) mounts="$directory (read-write)" ;;
    clone) mounts="$directory (read-only, with a Git remote back to the host)" ;;
  esac
  if [[ "$skills" != off ]]; then mounts="${mounts:+$mounts; }sbx skills store ($skills)"; fi
  command=(create --name "$name" --skills "$skills" --cpus "$cpus" --memory "$memory"
    --env "AGBX_AGENT=$agent" --env "AGBX_PLUGINS=$selected" "${kit_args[@]}")
  if [[ "$mode" == clone ]]; then command+=(--clone); fi
  command+=("$workload")
  case "$mode" in mount|clone) command+=("$directory") ;; esac
  case "$mode" in copy|mount) confirm_env_files "$directory" "$ack_env" "$dry" ;; esac
  if [[ "$mode" == copy ]]; then
    if [[ "$copy_all" == 0 ]]; then skips="$(copy_skips "$directory")"; fi
    copy_kib="$(copy_size "$directory" "$skips")"
  fi
  if [[ "$dry" == 1 ]]; then
    printf '%q ' "$SBX_BIN" "${command[@]}"; printf '\n'
    printf 'Workspace: %s%s\n' "$mode" "${directory:+ ($directory)}"
    if [[ "$mode" == copy ]]; then copy_summary "$copy_kib" "$skips"; fi
    printf 'Plugins: %s\n' "${selected:-none}"
    printf 'Host mounts: %s\n' "${mounts:-none}"
    printf 'Start detached, then configure Git identity. No credentials are copied.\n'
    return
  fi
  need_sbx
  memory_ok "$memory" || exit 1
  warn_host_wide_agent_secret "$agent"
  # Ask for the selected plugins' keys before the long provisioning run. Each
  # stays with this sandbox; blank skips.
  if [[ -t 0 && -t 1 ]]; then
    if has_plugin gh-auth; then
      printf '\nGitHub: a fine-grained token (Contents read/write, Metadata read-only) from\n'
      printf '  https://github.com/settings/personal-access-tokens/new\n'
      printf 'sbx keeps it for this sandbox only; the sandbox sees a placeholder.\n'
      read_secret gh_token 'GitHub token (blank to skip): '
    fi
    if has_plugin 1pass; then
      printf '\n1Password: a service account token from https://start.1password.com/settings/automation\n'
      printf 'op needs it inside the sandbox, where the agent can read it.\n'
      read_secret op_token '1Password token (blank to skip): '
    fi
    if has_plugin tailscale; then
      printf '\nTailscale: a tagged auth key from https://login.tailscale.com/admin/settings/keys\n'
      read_secret ts_key 'Tailscale auth key (blank to join later): '
      if [[ -n "$ts_key" ]] && ! has_plugin supabase-serve; then
        read_value ts_port 'Dev port to serve on :443 (blank to skip): '
        [[ -z "$ts_port" || "$ts_port" =~ $port_re ]] || die "Not a port: $ts_port"
      fi
    fi
  fi
  # Echo the choice: a mis-keyed toggle in the selector is otherwise silent.
  log "Agent: $agent; plugins: ${selected:-none}"
  # sbx create refuses duplicate names. Never remove or recreate an existing sandbox.
  sbx "${command[@]}"
  register "$name"
  # Quiet: it prints only the sandbox ID.
  sbx run --detached --name "$name" >/dev/null || created_but "$name" 'starting it'
  if [[ "$mode" == copy ]]; then
    log "Copying $directory into /workspace, including .git and uncommitted files"
    copy_summary "$copy_kib" "$skips"
    sbx exec --user root "$name" install -d -o 1000 -g 1000 /home/agent/workspace ||
      created_but "$name" 'preparing /workspace'
    copy_workspace "$name" "$directory" "$skips" "$((copy_kib * 1024))" || created_but "$name" "copying $directory"
  fi
  for identity in name email; do
    if [[ -n "$directory" ]]; then
      value="$(git -C "$directory" config --get "user.$identity" 2>/dev/null || true)"
    else
      value="$(git config --global --get "user.$identity" 2>/dev/null || true)"
    fi
    if [[ -n "$value" ]]; then
      sbx exec "$name" git config --global "user.$identity" "$value" ||
        created_but "$name" 'setting the Git identity'
    fi
  done
  if [[ -n "$gh_token" ]]; then
    printf '%s' "$gh_token" | sbx secret set --sandbox "$name" github ||
      warn "Storing the GitHub token failed; retry with: agbx auth github $name"
  elif has_plugin gh-auth; then
    printf 'Add a GitHub token later: agbx auth github %s\n' "$name"
  fi
  if [[ -n "$op_token" ]]; then
    printf 'export OP_SERVICE_ACCOUNT_TOKEN=%q\n' "$op_token" | write_guest_env "$name" OP_SERVICE_ACCOUNT_TOKEN ||
      warn "Storing the 1Password token failed; retry with: agbx env $name OP_SERVICE_ACCOUNT_TOKEN"
  elif has_plugin 1pass; then
    printf 'Add a 1Password token later: agbx env %s OP_SERVICE_ACCOUNT_TOKEN\n' "$name"
  fi
  gh_token="" op_token=""
  if [[ -n "$ts_key" ]]; then
    if printf '%s\n' "$ts_key" | sbx exec -i --user root "$name" /usr/local/bin/agbx-tailscale join "$name" --auth-key-stdin; then
      if [[ -n "$ts_port" ]]; then
        sbx exec --user root "$name" /usr/local/bin/agbx-tailscale serve "$ts_port" ||
          warn "Serving port $ts_port failed; retry with: agbx tailscale serve $name $ts_port"
      fi
    else
      warn "Joining the tailnet failed; retry with: agbx tailscale join $name"
    fi
    ts_key=""
  elif has_plugin tailscale; then
    printf 'Join your tailnet: agbx tailscale join %s\n' "$name"
  fi
  if has_plugin tailscale; then
    printf 'Once joined, the sandbox reaches whatever your tailnet ACLs allow, outside sbx network policy.\n'
  fi
  offer_agent_login "$name"
  # Last, after sbx's own "To connect" hint, so this is what stays on screen.
  printf '\nTo open a shell in the sandbox, run:\n  » agbx %s\n' "$name"
  if [[ "$agent" != shell ]]; then printf 'Start the agent with: agbx run %s\n' "$name"; fi
  printf 'Check the plugins with: agbx check %s\n' "$name"
}

cmd_shell() {
  local with_sudo=0 name line tty=(-i) cmd=(zsh -l)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-sudo) with_sudo=1; shift ;;
      -*) die "Unknown shell option: $1" ;;
      *) break ;;
    esac
  done
  [[ $# -ge 1 ]] || die 'Usage: shell [--with-sudo] NAME [COMMAND...]'
  name="$1"; shift
  need_sandbox "$name"
  if [[ $# == 0 ]]; then offer_agent_login "$name"; fi
  if [[ -t 0 && -t 1 ]]; then tty=(-it); fi
  # One argument is a command line; several are a command and its
  # arguments, quoted so their boundaries survive zsh.
  if [[ $# == 1 ]]; then
    cmd=(zsh -lc "$1")
  elif [[ $# -gt 1 ]]; then
    printf -v line '%q ' "$@"
    cmd=(zsh -lc "${line% }")
  fi
  if [[ "$with_sudo" == 1 ]]; then
    # Root enters and drops to agent with the _sudo group for this session only.
    sbx exec "${tty[@]}" --user root "$name" /usr/local/bin/agbx-sudo-session "${cmd[@]}"
  else
    sbx exec "${tty[@]}" "$name" "${cmd[@]}"
  fi
}

cmd_run() {
  [[ $# -ge 1 ]] || die 'Usage: run NAME [-- AGENT_ARGS...]'
  local name="$1"
  shift
  need_sandbox "$name"
  offer_agent_login "$name"
  if [[ "${1:-}" == -- ]]; then shift; fi
  if [[ $# -gt 0 ]]; then sbx run --name "$name" -- "$@"; else sbx run --name "$name"; fi
}

cmd_exec() {
  [[ $# -ge 2 ]] || die 'Usage: exec NAME COMMAND [ARGS...]'
  need_sandbox "$1"
  if [[ -t 0 ]]; then sbx exec "$@"; else sbx exec -i "$@"; fi
}

cmd_stop() {
  [[ $# == 1 ]] || die 'Usage: stop NAME'
  need_sandbox "$1"
  sbx stop "$1"
  log "Stopped $1"
}

cmd_stop_all() {
  local states name status stopped=0
  need_sbx
  states="$(managed_states kill-all)"
  while read -r name status; do
    [[ -n "$name" && "$status" == running ]] || continue
    sbx stop "$name" </dev/null
    log "Stopped $name"
    stopped=1
  done <<< "$states"
  [[ "$stopped" == 1 ]] || echo 'No running agbx sandboxes'
}

cmd_delete() {
  [[ $# == 1 ]] || die 'Usage: delete NAME'
  need_sandbox "$1"
  # sbx asks for confirmation and also removes secrets scoped to the sandbox.
  sbx rm "$1" || true
  if sandbox_exists "$1"; then die "$1 was not deleted"; fi
  unregister "$1"
  log "Deleted $1"
}

resolve_host() {
  local ip=""
  if command -v getent >/dev/null 2>&1; then
    ip="$(getent hosts "$1" | awk '{print $1; exit}')"
  elif command -v dscacheutil >/dev/null 2>&1; then
    ip="$(dscacheutil -q host -a name "$1" | awk '/^ip_address:/ {print $2; exit}')"
  fi
  [[ -n "$ip" ]] && printf '%s\n' "$ip"
}

cmd_net() {
  [[ $# -ge 1 ]] || die 'Usage: net NAME [-b ADDR|-H HOST] [-l] [-r PORT] [PORT|HOST_PORT:SANDBOX_PORT ...]'
  local name="$1" bind=127.0.0.1 action=add port re='^[0-9]+(:[0-9]+)?$' arg
  local publish=() unpublish=()
  shift
  need_sandbox "$name"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -b|--bind) need_value "$@"; bind="$2"; shift 2 ;;
      -H|--host) need_value "$@"; bind="$(resolve_host "$2")" || die "Could not resolve $2"; shift 2 ;;
      -l|--list) action=list; shift ;;
      -r|--remove)
        need_value "$@"
        [[ "$2" != all ]] || die 'Remove ports one at a time; list them with net NAME -l.'
        [[ "$2" =~ $re ]] || die "Expected PORT or HOST_PORT:SANDBOX_PORT, got $2"
        case "$2" in *:*) arg="$2" ;; *) arg="$2:$2" ;; esac
        unpublish+=(--unpublish "$arg"); shift 2 ;;
      -h|--help) usage; return ;;
      -*) die "Unknown net option: $1" ;;
      *)
        port="$1"; shift
        [[ "$port" =~ $re ]] || die "Expected PORT or HOST_PORT:SANDBOX_PORT, got $port"
        case "$port" in *:*) arg="$bind:$port" ;; *) arg="$bind:$port:$port" ;; esac
        publish+=(--publish "$arg") ;;
    esac
  done
  if [[ "$action" == list || ( ${#publish[@]} == 0 && ${#unpublish[@]} == 0 ) ]]; then
    sbx ports "$name"
    return
  fi
  sbx ports "$name" "${publish[@]+"${publish[@]}"}" "${unpublish[@]+"${unpublish[@]}"}"
}

cmd_env() {
  [[ $# == 2 ]] || die 'Usage: env NAME VAR_NAME'
  local name="$1" var="$2" pair service="" value re='^[A-Za-z_][A-Za-z0-9_]*$'
  [[ "$var" =~ $re ]] || die "Invalid variable name: $var"
  need_sandbox "$name"
  for pair in $SERVICE_VARS; do
    if [[ "${pair%%:*}" == "$var" ]]; then service="${pair#*:}"; fi
  done
  if [[ -t 0 ]]; then
    read_secret value "Enter value for $var (input hidden, paste ok): "
  else
    IFS= read -r value || true
  fi
  [[ -n "$value" ]] || die 'Value required'
  if [[ -n "$service" ]]; then
    printf '%s' "$value" | sbx secret set --sandbox "$name" "$service"
    log "Stored $var as $name's sbx $service secret; the proxy injects it and the sandbox sees a placeholder."
    return
  fi
  # The value travels on stdin, never as an argument.
  printf 'export %s=%q\n' "$var" "$value" | write_guest_env "$name" "$var"
  log "Set $var in $name. The sandbox and its agent can read it; for API keys prefer sbx secret set-custom."
}

cmd_update() {
  [[ $# == 1 ]] || die 'Usage: update NAME'
  need_sandbox "$1"
  sbx exec --user root "$1" sh -c "$UPDATE_SCRIPT"
  log "Updated $1"
}

write_status() {
  mkdir -p "$STATE_DIR"
  printf 'status=%s\ndate=%s\ndetails=%s\n' "$1" "$(date '+%Y-%m-%d %H:%M')" "${2:-}" > "$STATE_DIR/last-update"
}

cmd_update_all() {
  local states name status failed="" logfile
  need_sbx
  states="$(managed_states update-all)"
  if [[ -z "$states" ]]; then echo 'No agbx sandboxes found'; return; fi
  mkdir -p "$LOG_DIR"
  logfile="$LOG_DIR/update-$(date +%Y%m%d-%H%M%S).log"
  while read -r name status; do
    [[ -n "$name" ]] || continue
    if [[ "$status" != running ]]; then
      if ! memory_ok "${AGBX_MEMORY:-4g}"; then failed="$failed $name"; continue; fi
      log "Starting $name..."
      if ! sbx run --detached --name "$name" </dev/null >/dev/null; then failed="$failed $name"; continue; fi
    fi
    log "Updating $name..."
    printf '=== %s %s ===\n' "$name" "$(date)" >> "$logfile"
    if ! sbx exec --user root "$name" sh -c "$UPDATE_SCRIPT" </dev/null >> "$logfile" 2>&1; then
      failed="$failed $name"
    fi
    # Only stop sandboxes that were stopped before.
    if [[ "$status" != running ]]; then
      log "Stopping $name..."
      sbx stop "$name" </dev/null >/dev/null || true
    fi
  done <<< "$states"
  if [[ -n "$failed" ]]; then
    printf 'Failed:%s\nSee %s\n' "$failed" "$logfile" >&2
    write_status failed "${failed# }"
    exit 1
  fi
  rm -f "$logfile"
  write_status ok
  log 'All agbx sandboxes updated'
}

cmd_cron() {
  local hour line
  case "${1:-}" in
    install)
      hour="${2:-19}"
      [[ "$hour" =~ ^[0-9]+$ && "$hour" -le 23 ]] || die "Invalid hour: $hour (0-23)"
      mkdir -p "$LOG_DIR"
      # cron's PATH is minimal; keep the one that finds sbx and jq now.
      line="0 $hour * * * PATH=$(printf '%q' "$PATH") $(printf '%q' "$PROJECT_DIR/agbx") update-all >> $(printf '%q' "$LOG_DIR/cron.log") 2>&1 $CRON_TAG"
      { { crontab -l 2>/dev/null || true; } | { grep -vF "$CRON_TAG" || true; }; printf '%s\n' "$line"; } | crontab -
      log "Installed cron: daily at $(printf '%02d' "$((10#$hour))"):00; logs in $LOG_DIR/cron.log"
      ;;
    remove)
      { crontab -l 2>/dev/null || true; } | { grep -vF "$CRON_TAG" || true; } | crontab -
      log 'Removed the agbx update cron'
      ;;
    status)
      line="$(crontab -l 2>/dev/null | grep -F "$CRON_TAG" || true)"
      if [[ -n "$line" ]]; then echo "Active: $line"; else echo 'No agbx update cron installed'; fi
      ;;
    *) die 'Usage: cron install [HOUR]|remove|status' ;;
  esac
}

cmd_status() {
  need_sbx
  case "${1:-}" in
    --once) sbx ls ;;
    '') if [[ -t 0 && -t 1 ]]; then sbx tui; else sbx ls; fi ;;
    *) die 'Usage: status [--once]' ;;
  esac
}

auth() {
  [[ $# -ge 2 ]] || die 'auth requires a provider and sandbox name'
  local provider="$1" name="$2" token gh_path
  shift 2
  need_sandbox "$name"
  case "$provider" in
    github)
      [[ $# == 0 || ( $# == 1 && "$1" == --from-gh ) ]] || die 'Use: auth github NAME [--from-gh]'
      if [[ $# == 1 ]]; then
        gh_path="$(type -P gh)" || die 'Install and sign in to gh on the host first.'
        printf 'Using the host gh token; it carries every scope gh was granted.\n' >&2
        # sbx runs command secrets from a temporary directory, and its daemon's
        # PATH may not include gh's; use an absolute path.
        sbx secret set --sandbox "$name" github --command "$(printf '%q' "$gh_path") auth token"
      elif [[ -t 0 ]]; then
        printf 'Create a fine-grained token at https://github.com/settings/personal-access-tokens/new\n' >&2
        printf 'Recommended permissions: Contents read/write, Metadata read-only.\n' >&2
        read_secret token 'GitHub token: '
        [[ -n "$token" ]] || die 'GitHub token required'
        printf '%s' "$token" | sbx secret set --sandbox "$name" github
      else
        # A token piped in goes straight to sbx.
        sbx secret set --sandbox "$name" github
      fi
      ;;
    1password)
      [[ $# == 2 && "$2" == op://* ]] || die 'Use: auth 1password NAME SERVICE op://VAULT/ITEM/FIELD'
      command -v op >/dev/null || die 'Install and sign in to op on the host first.'
      sbx secret set --sandbox "$name" "$1" --ref "$2"
      ;;
    *) die "Unknown credential source: $provider" ;;
  esac
}

tailscale_command() {
  [[ $# -ge 2 ]] || die 'tailscale requires join/status/serve and a sandbox name'
  local action="$1" name="$2"
  shift 2
  need_sandbox "$name"
  case "$action" in
    join)
      if [[ $# == 0 ]]; then
        sbx exec --user root "$name" /usr/local/bin/agbx-tailscale join "$name"
      elif [[ $# == 1 && "$1" == --auth-key-stdin ]]; then
        [[ ! -t 0 ]] || die 'Pipe an auth key on stdin; do not pass it as an argument.'
        sbx exec -i --user root "$name" /usr/local/bin/agbx-tailscale join "$name" --auth-key-stdin
      else die 'Use: tailscale join NAME [--auth-key-stdin]'; fi
      ;;
    status)
      [[ $# == 0 ]] || die 'status accepts only a sandbox name'
      sbx exec --user root "$name" tailscale status ;;
    serve)
      [[ $# == 1 ]] || die 'Use: tailscale serve NAME PORT|supabase'
      sbx exec --user root "$name" /usr/local/bin/agbx-tailscale serve "$1" ;;
    *) die "Unknown tailscale action: $action" ;;
  esac
}

# Compare dotted versions: version_ge 0.47.1 0.47.0
version_ge() {
  local IFS=. i x y a b
  a=($1); b=($2)
  for i in 0 1 2; do
    x="${a[i]:-0}"; y="${b[i]:-0}"
    if (( 10#$x > 10#$y )); then return 0; fi
    if (( 10#$x < 10#$y )); then return 1; fi
  done
  return 0
}

cmd_doctor() {
  local version service
  need_sbx
  version="$(sbx version 2>/dev/null | sed -n 's/.*version: v\{0,1\}\([0-9][0-9.]*\).*/\1/p' | head -1)"
  [[ -n "$version" ]] || die 'Could not read the sbx version'
  version_ge "$version" "$MIN_SBX_VERSION" ||
    die "sbx $version is too old; agbx needs $MIN_SBX_VERSION or newer."
  printf 'sbx %s\n' "$version"
  if [[ "$(uname -s)" == Linux ]]; then
    [[ -r /dev/kvm && -w /dev/kvm ]] || die '/dev/kvm is not accessible; local sandboxes need KVM and kvm group membership.'
  fi
  command -v jq >/dev/null 2>&1 || printf 'Note: kill-all and update-all need jq.\n'
  for service in anthropic openai; do
    if host_wide_secret "$service"; then
      printf 'Note: a host-wide %s secret replaces each sandbox'"'"'s own sign-in (sbx secret rm %s).\n' "$service" "$service"
    fi
  done
  sbx ls
}

cmd_validate() {
  local kit failed=0
  need_sbx
  for kit in "$PROJECT_DIR"/kits/* "$PROJECT_DIR"/agents/*; do
    sbx kit validate "$kit" || failed=1
  done
  [[ "$failed" == 0 ]] || die 'Some kits failed validation'
}

main() {
  local command="${1:-help}"
  if [[ $# != 0 ]]; then shift; fi
  case "$command" in
    help|-h|--help) usage ;;
    plugins) cat "$PROJECT_DIR/plugins.tsv" ;;
    create|init|-i) create "$@" ;;
    shell|-s) cmd_shell "$@" ;;
    run) cmd_run "$@" ;;
    exec) cmd_exec "$@" ;;
    stop|kill|-k) cmd_stop "$@" ;;
    kill-all|-ka) cmd_stop_all ;;
    delete|-d) cmd_delete "$@" ;;
    net|-n) cmd_net "$@" ;;
    env|-e) cmd_env "$@" ;;
    update|-u) cmd_update "$@" ;;
    update-all|-ua) cmd_update_all ;;
    cron) cmd_cron "$@" ;;
    status) cmd_status "$@" ;;
    ls) need_sbx; sbx ls "$@" ;;
    check)
      [[ $# == 1 ]] || die 'Usage: check NAME'
      need_sandbox "$1"
      sbx exec "$1" bash /home/agent/.local/share/agbx/check.sh ;;
    auth) auth "$@" ;;
    tailscale) tailscale_command "$@" ;;
    validate) cmd_validate ;;
    doctor) cmd_doctor ;;
    -*) die "Unknown option: $command (try --help)" ;;
    # A bare name opens a shell.
    *) cmd_shell "$command" "$@" ;;
  esac
}
