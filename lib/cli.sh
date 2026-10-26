# Sourced by bxn. Credentials are never accepted as command arguments.
# Bash 3.2: no associative arrays; guard empty arrays under set -u.

# Optional mixins in install order; rtkplus stands for the agent's own RTK
# mixin. Every tool is baked into the workload, so there is nothing else to
# choose; supabase-serve is an option on tailscale, not a kit.
KITS="tailscale gh-auth 1pass rtkplus"
PLUGINS="tailscale supabase-serve gh-auth 1pass rtkplus"
# No kit is selected by default.
DEFAULT_PLUGINS=""
AGENTS="shell claude codex grok"
# env variables that sbx can inject through its proxy instead of the guest.
SERVICE_VARS="ANTHROPIC_API_KEY:anthropic OPENAI_API_KEY:openai XAI_API_KEY:xai GH_TOKEN:github GITHUB_TOKEN:github GROQ_API_KEY:groq MISTRAL_API_KEY:mistral OPENROUTER_API_KEY:openrouter GEMINI_API_KEY:google GOOGLE_API_KEY:google"
# sbx 0.48 renamed run --detached to --detach and prints ls --json as a bare
# array; boxen passes run -d and reads either listing, so 0.47 still works.
MIN_SBX_VERSION=0.47.0
STATE_DIR="${BOXEN_STATE_DIR:-$HOME/.local/state/boxen}"
# sbx's approval record for third-party kit credentials; install writes the
# github binding, since a detached sandbox never sees sbx's approval prompt.
SBX_CREDENTIALS="${BOXEN_SBX_CREDENTIALS:-$HOME/.config/sbx/credentials.yaml}"
github_binding_present() {
  [[ -f "$SBX_CREDENTIALS" ]] && grep -Eq '^[[:space:]]+github:[[:space:]]*$' "$SBX_CREDENTIALS"
}
REGISTRY="$STATE_DIR/sandboxes"
LOG_DIR="$STATE_DIR/logs"
CRON_TAG="# boxen-update-all"
UPDATE_SCRIPT='export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get upgrade -y'

die() { printf 'bxn: %s\n' "$*" >&2; exit 1; }
log() { printf '[+] %s\n' "$*"; }
warn() { printf 'bxn: %s\n' "$*" >&2; }
# Call sbx by the path need_sbx resolved. Not `command sbx`: in Bash 3.2 a
# failing `command` inside a function exits under set -e even within ||.
SBX_PATH=""
sbx() { "$SBX_PATH" "$@"; }
need_sbx() {
  SBX_PATH="$(type -P "$SBX_BIN")" || die 'Install sbx and run sbx login first; see README.md.'
}
# sbx builds the v3 kits with Docker.
docker_builder_ok() { "$DOCKER_BIN" info >/dev/null 2>&1 && "$DOCKER_BIN" buildx version >/dev/null 2>&1; }
need_docker() { docker_builder_ok || die 'Install Docker and start it; sbx builds local v3 kits with it.'; }
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
drop_plugin() {
  selected=",$selected,"
  selected="${selected/,$1,/,}"
  selected="${selected#,}"; selected="${selected%,}"
}
# One line a shell reads back the same way: plain words bare, the rest in
# single quotes, so --allow-network '**' prints as the CLI documents it.
print_command() {
  local arg out="" safe='^[A-Za-z0-9_./:=+@%-]+$'
  for arg in "$@"; do
    if [[ "$arg" =~ $safe ]]; then out="$out $arg"
    elif [[ "$arg" != *"'"* ]]; then out="$out '$arg'"
    else out="$out $(printf '%q' "$arg")"; fi
  done
  printf '%s\n' "${out# }"
}
set_agent() {
  [[ -z "$agent" || "$agent" == "$1" ]] ||
    die "One agent per sandbox: got $agent and $1. Create a second sandbox for the other agent."
  agent="$1"
}

usage() {
  cat <<'EOF'
bxn create NAME [DIRECTORY] [options]        (also: init, -i)
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
  --tailscale --supabase-serve --gh-token --1pass --rtkplus
  --claude --codex --grok        Shorthand flags; added to the selection
  --gh-token-stdin               Read the GitHub token from stdin's first line
  --open-network                 Allow every host (sbx --allow-network '**');
                                 kit rules then add nothing
  --cpus N --memory SIZE         Default: 4 CPUs (at most the host's), 4g
  --ack-env                      Copy .env files without asking
  --copy-all                     Also copy node_modules, deps, _build and other
                                 folders the sandbox rebuilds
  --no-tui                       Skip the interactive selector; use flags and defaults
  --dry-run                      Print the creation plan without creating

bxn NAME                                     Open zsh in the sandbox
bxn shell [--with-sudo] NAME [COMMAND...]    (also: -s) --with-sudo grants
                                             sudo for this session only
bxn run NAME [-- ARGS...]                    Attach to its agent
bxn exec NAME COMMAND [ARGS...]              Run a command
bxn net NAME [-b ADDR|-H HOST] [-l] [-r PORT] [PORT|HOST:SANDBOX ...]
                                             (also: -n) Publish ports on the host
bxn env NAME VAR                             (also: -e) Set a variable; prompts silently
bxn stop NAME                                (also: kill, -k)
bxn kill-all                                 (also: -ka) Stop all boxen sandboxes
bxn delete NAME                              (also: -d) sbx asks to confirm
bxn update NAME                              (also: -u) apt-get upgrade as root
bxn update-all                               (also: -ua)
bxn cron install [HOUR]|remove|status        Nightly update-all (default 19:00)
bxn status [--once]                          sbx's dashboard, or its table once
bxn ls                                       List sandboxes
bxn check NAME                               Check installed plugins
bxn plugins                                  List the plugins and what they install
bxn validate                                 Validate the v3 kits using the installed sbx
bxn doctor                                   Check prerequisites

bxn auth github NAME [--from-gh]             Store a fine-grained token (stdin or
                                             prompt), or source the host gh token
bxn auth 1password NAME SERVICE OP_REFERENCE
                                             Source a credential from host op
bxn tailscale join NAME [--auth-key-stdin]
bxn tailscale status NAME
bxn tailscale serve NAME PORT|supabase       Publish HTTPS :443 or the seven preset routes
                                             (fetches a certificate; http needs no serve)

Commands that take NAME never create a sandbox; only create does.
EOF
}

# --- Sandboxes ---------------------------------------------------------------

# 0 when NAME is listed, 1 when it is not, 2 when the listing fails.
listed() {
  local names
  names="$(sbx ls --quiet </dev/null)" || return 2
  printf '%s\n' "$names" | grep -Fxq -- "$1"
}
sandbox_exists() {
  local status=0
  listed "$1" || status=$?
  [[ "$status" != 2 ]] || die 'sbx ls failed; check bxn doctor.'
  [[ "$status" == 0 ]]
}
# Every command that takes NAME checks first, so a typo can never reach a
# command such as sbx run that creates a missing sandbox.
need_sandbox() {
  valid_name "$1"
  need_sbx
  sandbox_exists "$1" ||
    die "No sandbox named $1 (see bxn ls). Nothing was created; use bxn create $1."
}
# The registry has one line per sandbox: its NAME. A registry from before
# 2026-10-24 may also hold NAME<TAB>cloud rows for Docker Cloud sandboxes;
# those name sandboxes boxen no longer manages, so they are never read as
# local ones (a local sandbox with the same name is not boxen's).
registry_names() { [[ -f "$REGISTRY" ]] && awk -F'\t' '$2 != "cloud" { print $1 }' "$REGISTRY"; }
registered() { registry_names | grep -Fxq -- "$1"; }
register() {
  mkdir -p "$STATE_DIR"
  registered "$1" || printf '%s\n' "$1" >> "$REGISTRY"
}
unregister() {
  [[ -f "$REGISTRY" ]] || return 0
  awk -F'\t' -v name="$1" '$1 != name' "$REGISTRY" > "$REGISTRY.tmp"
  mv "$REGISTRY.tmp" "$REGISTRY"
}
# "NAME STATUS" for each sandbox boxen created that still exists.
managed_states() {
  local names json
  need_jq "$1"
  [[ -s "$REGISTRY" ]] || return 0
  names="$(registry_names)"
  [[ -n "$names" ]] || return 0
  json="$(sbx ls --json </dev/null)" || die 'sbx ls failed; check bxn doctor.'
  printf '%s' "$json" | jq -r --arg registry "$names" '
    ($registry | split("\n") | map(select(length > 0))) as $names
    | (.sandboxes? // .)[]? | select(.name as $n | $names | index($n)) | "\(.name) \(.status)"'
}
# Root work through sbx exec --user root. as_root NAME [-i] CMD...
as_root() {
  local name="$1" stdin=()
  shift
  if [[ "${1:-}" == -i ]]; then stdin=(-i); shift; fi
  sbx exec ${stdin[@]+"${stdin[@]}"} --user root "$name" "$@"
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
  local meminfo="${BOXEN_MEMINFO:-/proc/meminfo}" need avail
  [[ "${BOXEN_SKIP_MEMORY_CHECK:-0}" != 1 && -r "$meminfo" ]] || return 0
  need="$(to_kib "$1")" || die "Invalid memory size: $1"
  avail="$(awk '/^MemAvailable:/ {print $2}' "$meminfo")"
  [[ -n "$avail" ]] || return 0
  if (( avail < need + 1048576 )); then
    printf 'bxn: Only %s MiB of memory is available; a %s sandbox needs %s MiB plus 1024 MiB headroom.\n' \
      "$((avail / 1024))" "$1" "$((need / 1024))" >&2
    printf 'Stop another sandbox or pass a smaller --memory. BOXEN_SKIP_MEMORY_CHECK=1 skips this check.\n' >&2
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
# Shown once per create with the tailscale plugin (Supabase Serve adds it):
# the node is tagged tag:boxen, so the tailnet policy decides who reaches it.
tailnet_policy_hint() {
  cat <<'EOF'

Tailnet policy: if tag:boxen is not in it yet, add this (merge it into your
existing rules; it replaces nothing):
  {
    "tagOwners": {"tag:boxen": ["autogroup:admin"]},
    "acls": [
      {
        "action": "accept", "proto": "tcp",
        "src": ["autogroup:member"],
        "dst": ["tag:boxen:443,4410,4431,5432,5433,5434,8443"]
      }
    ]
    // No "funnel" nodeAttrs entry may target tag:boxen or "*".
  }
There is more than one way to write this. If your policy already says who may
reach everything, that rule covers sandboxes too and the acl above adds nothing:
  {"action": "accept", "src": ["group:admin"], "dst": ["*:*"]}
What matters either way: tag:boxen is in tagOwners, no rule has tag:boxen as
src, and no funnel nodeAttrs entry names it. Read up before editing:
https://tailscale.com/kb/1018/acls and the README, "Tailscale and previews".
EOF
}
created_but() {
  printf 'bxn: Sandbox %s was created, but %s failed.\n' "$1" "$2" >&2
  printf 'Look inside with: bxn shell %s\n' "$1" >&2
  printf 'To start over: bxn delete %s, then run create again.\n' "$1" >&2
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
# Run one of Boxen's guest scripts by name. The image keeps them under
# /usr/local/share/boxen/; a sandbox made before v3 has its own copies under
# /home/agent/.local/share/boxen/, so the probe tries both and never recreates
# anything. Callers set GUEST_TTY=(-it) when the script needs a terminal.
GUEST_TTY=()
guest_script() {
  local name="$1" script="$2"
  shift 2
  sbx exec ${GUEST_TTY[@]+"${GUEST_TTY[@]}"} "$name" sh -c '
    for p in /usr/local/share/boxen/"$1" /home/agent/.local/share/boxen/"$1"; do
      if [ -f "$p" ]; then shift; exec bash "$p" "$@"; fi
    done
    echo "boxen: $1 is not in the sandbox" >&2; exit 127' sh "$script" "$@"
}
# Offer the agent's subscription sign-in on the way in, when the sandbox needs
# one. Terminal only; anything unexpected skips the offer instead of blocking.
offer_agent_login() {
  local status=0 answer
  [[ -t 0 && -t 1 ]] || return 0
  GUEST_TTY=()
  guest_script "$1" agent-login.sh status </dev/null >/dev/null 2>&1 || status=$?
  [[ "$status" == 10 ]] || return 0
  read_value answer "$1's agent is not signed in. Sign in to your subscription now? [Y/n] "
  case "$answer" in n|N|no|No|NO) return 0 ;; esac
  GUEST_TTY=(-it)
  guest_script "$1" agent-login.sh login ||
    warn "Sign-in did not finish; bxn $1 offers it again."
  GUEST_TTY=()
}
# Reads `export VAR=value` on stdin and stores it in the sandbox, replacing any
# earlier value. The sandbox and its agent can read it.
write_guest_env() {
  sbx exec -i "$1" sh -c '
    umask 077
    dir="$HOME/.config/boxen"; file="$dir/env.sh"
    mkdir -p "$dir"; touch "$file"
    grep -v "^export $1=" "$file" > "$file.tmp" || true
    cat >> "$file.tmp"
    mv "$file.tmp" "$file"' sh "$2"
}

# --- Commands ----------------------------------------------------------------

create() {
  local name="" directory="" agent="" requested="$DEFAULT_PLUGINS" flagged="" mode=""
  local dry=0 ack_env=0 memory="${BOXEN_MEMORY:-4g}" cpus="${BOXEN_CPUS:-}"
  local copy_all=0 skips="" copy_kib=0
  # Nothing from the host is mounted unless asked: no workspace mount, no
  # shared skills store (sbx's own default is a read-only link).
  local skills=off mounts="" tui=1 chose_plugins=0 open_network=0
  local gh_stdin=0
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
      --tailscale|--supabase-serve|--1pass|--rtkplus)
        flagged="${flagged:+$flagged,}${1#--}"; shift ;;
      --gh-token) flagged="${flagged:+$flagged,}gh-auth"; shift ;;
      # The token is the first line of stdin: no terminal, nothing in argv.
      --gh-token-stdin) gh_stdin=1; flagged="${flagged:+$flagged,}gh-auth"; shift ;;
      --open-network) open_network=1; shift ;;
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
    in_list "$item" "$PLUGINS" || die "Unknown plugin: $item (see bxn plugins)"
    add_plugin "$item"
  done
  # The selector shows in a terminal unless --plugins already chose the kits.
  if [[ "$tui" == 1 && "$chose_plugins" == 0 && -t 0 && -t 1 ]]; then tui_select; fi
  if has_plugin supabase-serve; then add_plugin tailscale; fi
  if has_plugin rtkplus; then
    case "$agent" in
      claude|codex) ;;
      *) log "RTK hooks apply to Claude and Codex; not added for $agent"; drop_plugin rtkplus ;;
    esac
  fi
  # Without the binding the proxy withholds the token and GitHub sees the
  # placeholder, with nothing in the sandbox to say why.
  if has_plugin gh-auth && ! github_binding_present; then
    die "gh-auth needs sbx's approval to use the github secret, and a detached sandbox cannot ask for it. Run ./install, which writes the binding to $SBX_CREDENTIALS, then create again."
  fi
  if [[ -z "$cpus" ]]; then
    cpus="$(host_cpus)"
    if [[ "$cpus" -gt 4 ]]; then cpus=4; fi
  fi
  [[ -z "$cpus" || "$cpus" =~ ^[1-9][0-9]*$ ]] || die "Invalid --cpus: $cpus"
  [[ -z "$memory" ]] || to_kib "$memory" >/dev/null || die "Invalid --memory: $memory (for example 2g or 512m)"

  # Docker's agent mixin goes first, so Boxen's hooks run after its settings
  # seed; a shell box is the workload alone.
  kit_args=()
  if [[ "$agent" != shell ]]; then kit_args+=(--kit "$(mixin_ref "$agent")"); fi
  # Copied and empty workspaces get the agent-owned /workspace link; mounts
  # bring their own directory.
  case "$mode" in copy|none) kit_args+=(--kit "$PROJECT_DIR/v3/workspace") ;; esac
  for kit in $KITS; do
    has_plugin "$kit" || continue
    if [[ "$kit" == rtkplus ]]; then kit="rtkplus-$agent"; fi
    kit_args+=(--kit "$PROJECT_DIR/v3/$kit")
  done
  # The workload, with every tool baked in, is the positional.
  workload="$PROJECT_DIR/v3/boxen"
  case "$mode" in
    mount) mounts="$directory (read-write)" ;;
    clone) mounts="$directory (read-only, with a Git remote back to the host)" ;;
  esac
  if [[ "$skills" != off ]]; then mounts="${mounts:+$mounts; }sbx skills store ($skills)"; fi
  command=(create --name "$name" --skills "$skills")
  if [[ -n "$cpus" ]]; then command+=(--cpus "$cpus"); fi
  if [[ -n "$memory" ]]; then command+=(--memory "$memory"); fi
  command+=(--env "BOXEN_AGENT=$agent" --env "BOXEN_PLUGINS=$selected")
  if has_plugin supabase-serve; then command+=(--env BOXEN_SERVE_PRESET=supabase); fi
  # The literal two-asterisk argument; the account's or host's denies still win.
  if [[ "$open_network" == 1 ]]; then command+=(--allow-network '**'); fi
  command+=(${kit_args[@]+"${kit_args[@]}"})
  if [[ "$mode" == clone ]]; then command+=(--clone); fi
  command+=("$workload")
  case "$mode" in mount|clone) command+=("$directory") ;; esac
  case "$mode" in copy|mount) confirm_env_files "$directory" "$ack_env" "$dry" ;; esac
  if [[ "$mode" == copy ]]; then
    if [[ "$copy_all" == 0 ]]; then skips="$(copy_skips "$directory")"; fi
    copy_kib="$(copy_size "$directory" "$skips")"
  fi
  if [[ "$dry" == 1 ]]; then
    print_command "$SBX_BIN" "${command[@]}"
    printf 'Workspace: %s%s\n' "$mode" "${directory:+ ($directory)}"
    if [[ "$mode" == copy ]]; then copy_summary "$copy_kib" "$skips"; fi
    printf 'Plugins: %s\n' "${selected:-none}"
    printf 'Host mounts: %s\n' "${mounts:-none}"
    printf 'Start detached, then configure Git identity. No credentials are copied.\n'
    return
  fi
  need_sbx
  need_docker
  # The registry first, then sbx itself, before anything is made.
  if registered "$name"; then die "$name already names a boxen sandbox (see bxn ls)"; fi
  if sandbox_exists "$name"; then
    die "$name already exists (not made by boxen); pick another name or remove it with sbx rm $name"
  fi
  memory_ok "$memory" || exit 1
  warn_host_wide_agent_secret "$agent"
  if [[ "$gh_stdin" == 1 ]]; then IFS= read -r gh_token || true; fi
  # Ask for the selected plugins' keys before the long provisioning run. Each
  # stays with this sandbox; blank skips.
  if [[ -t 0 && -t 1 ]]; then
    if has_plugin gh-auth && [[ "$gh_stdin" == 0 ]]; then
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
      printf '\nTailscale: an auth key tagged tag:boxen from https://login.tailscale.com/admin/settings/keys\n'
      read_secret ts_key 'Tailscale auth key (blank to join later): '
      if [[ -n "$ts_key" ]] && has_plugin supabase-serve; then
        printf 'Supabase Serve publishes its routes over HTTPS. '; https_note
      elif [[ -n "$ts_key" ]]; then
        printf 'Previews: once joined, http://NODE.TAILNET.ts.net:PORT reaches any port the sandbox\n'
        printf 'listens on, with no certificate. Serving one port over HTTPS instead '; https_note
        read_value ts_port 'Dev port to serve over HTTPS on :443 (blank to stay on http): '
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
  sbx run -d --name "$name" >/dev/null || created_but "$name" 'starting it'
  if [[ "$mode" == copy ]]; then
    log "Copying $directory into /workspace, including .git and uncommitted files"
    copy_summary "$copy_kib" "$skips"
    # The workspace mixin's install hook made the directory, owned by the agent.
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
    printf '%s' "$gh_token" | sbx secret set --sandbox "$name" github --force ||
      warn "Storing the GitHub token failed; retry with: bxn auth github $name"
  elif has_plugin gh-auth; then
    printf 'Add a GitHub token later: bxn auth github %s\n' "$name"
  fi
  if [[ -n "$op_token" ]]; then
    printf 'export OP_SERVICE_ACCOUNT_TOKEN=%q\n' "$op_token" | write_guest_env "$name" OP_SERVICE_ACCOUNT_TOKEN ||
      warn "Storing the 1Password token failed; retry with: bxn env $name OP_SERVICE_ACCOUNT_TOKEN"
  elif has_plugin 1pass; then
    printf 'Add a 1Password token later: bxn env %s OP_SERVICE_ACCOUNT_TOKEN\n' "$name"
  fi
  gh_token="" op_token=""
  if [[ -n "$ts_key" ]]; then
    if printf '%s\n' "$ts_key" | as_root "$name" -i /usr/local/bin/boxen-tailscale join --auth-key-stdin; then
      if [[ -n "$ts_port" ]]; then
        as_root "$name" /usr/local/bin/boxen-tailscale serve "$ts_port" ||
          warn "Serving port $ts_port failed; retry with: bxn tailscale serve $name $ts_port"
      fi
    else
      warn "Joining the tailnet failed; retry with: bxn tailscale join $name"
    fi
    ts_key=""
  elif has_plugin tailscale; then
    printf 'Join your tailnet: bxn tailscale join %s\n' "$name"
  fi
  if has_plugin tailscale; then
    printf 'Once joined, the sandbox reaches whatever your tailnet ACLs allow, outside sbx network policy.\n'
    tailnet_policy_hint
  fi
  offer_agent_login "$name"
  # Last, after sbx's own "To connect" hint, so this is what stays on screen.
  printf '\nTo open a shell in the sandbox, run:\n  » bxn %s\n' "$name"
  if [[ "$agent" != shell ]]; then printf 'Start the agent with: bxn run %s\n' "$name"; fi
  printf 'Check the plugins with: bxn check %s\n' "$name"
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
    sbx exec "${tty[@]}" --user root "$name" /usr/local/bin/boxen-sudo-session "${cmd[@]}"
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
    [[ -n "$name" ]] || continue
    [[ "$status" == running ]] || continue
    sbx stop "$name" </dev/null
    log "Stopped $name"
    stopped=1
  done <<< "$states"
  [[ "$stopped" == 1 ]] || echo 'No running boxen sandboxes'
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
  as_root "$1" sh -c "$UPDATE_SCRIPT"
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
  if [[ -z "$states" ]]; then echo 'No boxen sandboxes found'; return; fi
  mkdir -p "$LOG_DIR"
  logfile="$LOG_DIR/update-$(date +%Y%m%d-%H%M%S).log"
  while read -r name status; do
    [[ -n "$name" ]] || continue
    if [[ "$status" != running ]]; then
      if ! memory_ok "${BOXEN_MEMORY:-4g}"; then failed="$failed $name"; continue; fi
      log "Starting $name..."
      if ! sbx run -d --name "$name" </dev/null >/dev/null; then failed="$failed $name"; continue; fi
    fi
    log "Updating $name..."
    printf '=== %s %s ===\n' "$name" "$(date)" >> "$logfile"
    if ! as_root "$name" sh -c "$UPDATE_SCRIPT" </dev/null >> "$logfile" 2>&1; then
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
  log 'All boxen sandboxes updated'
}

cmd_cron() {
  local hour line
  case "${1:-}" in
    install)
      hour="${2:-19}"
      [[ "$hour" =~ ^[0-9]+$ && "$hour" -le 23 ]] || die "Invalid hour: $hour (0-23)"
      mkdir -p "$LOG_DIR"
      # cron's PATH is minimal; keep the one that finds sbx and jq now.
      line="0 $hour * * * PATH=$(printf '%q' "$PATH") $(printf '%q' "$PROJECT_DIR/bxn") update-all >> $(printf '%q' "$LOG_DIR/cron.log") 2>&1 $CRON_TAG"
      { { crontab -l 2>/dev/null || true; } | { grep -vF "$CRON_TAG" || true; }; printf '%s\n' "$line"; } | crontab -
      log "Installed cron: daily at $(printf '%02d' "$((10#$hour))"):00; logs in $LOG_DIR/cron.log"
      ;;
    remove)
      { crontab -l 2>/dev/null || true; } | { grep -vF "$CRON_TAG" || true; } | crontab -
      log 'Removed the bxn update cron'
      ;;
    status)
      line="$(crontab -l 2>/dev/null | grep -F "$CRON_TAG" || true)"
      if [[ -n "$line" ]]; then echo "Active: $line"; else echo 'No bxn update cron installed'; fi
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
        # PATH may not include gh's; use an absolute path. --force: sbx 0.49
        # asks before replacing a stored secret, and only a terminal could answer.
        sbx secret set --sandbox "$name" github --command "$(printf '%q' "$gh_path") auth token" --force
      elif [[ -t 0 ]]; then
        printf 'Create a fine-grained token at https://github.com/settings/personal-access-tokens/new\n' >&2
        printf 'Recommended permissions: Contents read/write, Metadata read-only.\n' >&2
        read_secret token 'GitHub token: '
        [[ -n "$token" ]] || die 'GitHub token required'
        printf '%s' "$token" | sbx secret set --sandbox "$name" github --force
      else
        # A token piped in goes straight to sbx.
        sbx secret set --sandbox "$name" github --force
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
        as_root "$name" /usr/local/bin/boxen-tailscale join
      elif [[ $# == 1 && "$1" == --auth-key-stdin ]]; then
        [[ ! -t 0 ]] || die 'Pipe an auth key on stdin; do not pass it as an argument.'
        as_root "$name" -i /usr/local/bin/boxen-tailscale join --auth-key-stdin
      else die 'Use: tailscale join NAME [--auth-key-stdin]'; fi
      ;;
    status)
      [[ $# == 0 ]] || die 'status accepts only a sandbox name'
      as_root "$name" tailscale status ;;
    serve)
      [[ $# == 1 ]] || die 'Use: tailscale serve NAME PORT|supabase'
      printf 'HTTPS '; https_note
      as_root "$name" /usr/local/bin/boxen-tailscale serve "$1" ;;
    *) die "Unknown tailscale action: $action" ;;
  esac
}

# What serving over HTTPS makes public. Printed after a lead-in such as "HTTPS ".
https_note() {
  printf 'fetches a Let'"'"'s Encrypt certificate, which lists the node'"'"'s name in the public\n'
  printf 'certificate logs; the node itself stays reachable only from your tailnet.\n'
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
  local version service failed=0
  [[ $# == 0 ]] || die 'Usage: doctor'
  need_sbx
  version="$(sbx version 2>/dev/null | sed -n 's/.*version:\{0,1\} v\{0,1\}\([0-9][0-9.]*\).*/\1/p' | head -1)"
  [[ -n "$version" ]] || die 'Could not read the sbx version'
  version_ge "$version" "$MIN_SBX_VERSION" ||
    die "sbx $version is too old; boxen needs $MIN_SBX_VERSION or newer."
  printf 'sbx %s\n' "$version"
  # Every sandbox is a microVM on KVM.
  if [[ "${BOXEN_SKIP_KVM_CHECK:-0}" != 1 && "$(uname -s)" == Linux ]]; then
    [[ -r /dev/kvm && -w /dev/kvm ]] || die '/dev/kvm is not accessible; local sandboxes need KVM and kvm group membership.'
  fi
  if docker_builder_ok; then
    printf 'Docker builder: ok\n'
  else
    printf 'Docker builder: unavailable (sbx builds local v3 kits with it)\n'; failed=1
  fi
  command -v jq >/dev/null 2>&1 || printf 'Note: kill-all and update-all need jq.\n'
  if github_binding_present; then
    printf 'GitHub binding: ok\n'
  else
    printf 'GitHub binding: missing (run ./install; without it gh-auth sandboxes get no token)\n'
  fi
  for service in anthropic openai; do
    if host_wide_secret "$service"; then
      printf 'Note: a host-wide %s secret replaces each sandbox'"'"'s own sign-in (sbx secret rm %s).\n' "$service" "$service"
    fi
  done
  sbx ls
  [[ "$failed" == 0 ]] || exit 1
}

cmd_validate() {
  local kit failed=0
  need_sbx
  for kit in "$PROJECT_DIR"/v3/*; do
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
      GUEST_TTY=()
      guest_script "$1" check.sh ;;
    auth) auth "$@" ;;
    tailscale) tailscale_command "$@" ;;
    validate) cmd_validate ;;
    doctor) cmd_doctor "$@" ;;
    -*) die "Unknown option: $command (try --help)" ;;
    # A bare name opens a shell.
    *) cmd_shell "$command" "$@" ;;
  esac
}
