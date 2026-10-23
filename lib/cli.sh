# Sourced by boxen. Credentials are never accepted as command arguments.
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
MIN_SBX_VERSION=0.47.0
STATE_DIR="${BOXEN_STATE_DIR:-$HOME/.local/state/boxen}"
REGISTRY="$STATE_DIR/sandboxes"
LOG_DIR="$STATE_DIR/logs"
CRON_TAG="# boxen-update-all"
UPDATE_SCRIPT='export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get upgrade -y'
TUNNEL_STATE="$STATE_DIR/tunnels"
# The app and Supabase's local ports, as boxen tailscale serve NAME supabase routes them.
SUPABASE_PORTS="3000 3010 3001 54321 54323 54324 8000"
TTL_MESSAGE='BOXEN_CLOUD_TTL must be hours from 1 to 24 (8 or 8h) or minutes from 5 to 59 (5m)'

die() { printf 'boxen: %s\n' "$*" >&2; exit 1; }
log() { printf '[+] %s\n' "$*"; }
warn() { printf 'boxen: %s\n' "$*" >&2; }
# Call sbx by the path need_sbx resolved. Not `command sbx`: in Bash 3.2 a
# failing `command` inside a function exits under set -e even within ||.
SBX_PATH=""
# 1 sends every sbx call to Docker Cloud. create --cloud sets it; need_sandbox
# sets it from the registry, so later commands follow the sandbox.
CLOUD=0
sbx() { if [[ "$CLOUD" == 1 ]]; then "$SBX_PATH" --cloud "$@"; else "$SBX_PATH" "$@"; fi; }
need_sbx() {
  SBX_PATH="$(type -P "$SBX_BIN")" || die 'Install sbx and run sbx login first; see README.md.'
}
# sbx builds local v3 kits with Docker, for local and cloud sandboxes alike.
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
boxen create NAME [DIRECTORY] [options]      (also: init, -i)
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
  --cloud                        Create in Docker Cloud: copy or empty workspace,
                                 keeps sudo, stops (never deletes) after
                                 BOXEN_CLOUD_TTL (hours 1-24, default 8; or 5m-59m)
  --cpus N --memory SIZE         Default: 4 CPUs (at most the host's), 4g
  --ack-env                      Copy .env files without asking
  --copy-all                     Also copy node_modules, deps, _build and other
                                 folders the sandbox rebuilds
  --no-tui                       Skip the interactive selector; use flags and defaults
  --dry-run                      Print the creation plan without creating

boxen NAME                                   Open zsh in the sandbox
boxen shell [--with-sudo] NAME [COMMAND...]  (also: -s) --with-sudo grants
                                             sudo for this session only
boxen run NAME [-- ARGS...]                  Attach to its agent
boxen exec NAME COMMAND [ARGS...]            Run a command
boxen net NAME [-b ADDR|-H HOST] [-l] [-r PORT] [PORT|HOST:SANDBOX ...]
                                             (also: -n) Publish ports on the host;
                                             on a cloud sandbox, an SSH tunnel to
                                             127.0.0.1 here (supabase forwards the
                                             seven Supabase ports; no ports reopens)
boxen env NAME VAR                           (also: -e) Set a variable; prompts silently
boxen stop NAME                              (also: kill, -k)
boxen kill-all                               (also: -ka) Stop all boxen sandboxes
boxen delete NAME                            (also: -d) sbx asks to confirm
boxen update NAME                            (also: -u) apt-get upgrade as root
boxen update-all                             (also: -ua)
boxen cron install [HOUR]|remove|status      Nightly update-all (default 19:00)
boxen status [--once]                        sbx's dashboard, or its table once
boxen ls                                     List sandboxes
boxen check NAME                             Check installed plugins
boxen plugins                                List the plugins and what they install
boxen validate                               Validate the v3 kits using the installed sbx
boxen doctor [--cloud]                       Check prerequisites; --cloud needs no KVM

boxen auth github NAME [--from-gh]           Store a fine-grained token (stdin or
                                             prompt), or source the host gh token
boxen auth 1password NAME SERVICE OP_REFERENCE
                                             Source a credential from host op
boxen tailscale join NAME [--auth-key-stdin]
boxen tailscale status NAME
boxen tailscale serve NAME PORT|supabase     Publish HTTPS :443 or the seven preset routes

Commands that take NAME never create a sandbox; only create does.
EOF
}

# --- Sandboxes ---------------------------------------------------------------

# On the backend CLOUD selects: 0 when NAME is listed, 1 when it is not, 2
# when the listing fails.
listed() {
  local names
  names="$(sbx ls --quiet </dev/null)" || return 2
  printf '%s\n' "$names" | grep -Fxq -- "$1"
}
sandbox_exists() {
  local status=0
  listed "$1" || status=$?
  [[ "$status" != 2 ]] || die 'sbx ls failed; check boxen doctor.'
  [[ "$status" == 0 ]]
}
# Every command that takes NAME checks first, so a typo can never reach a
# command such as sbx run that creates a missing sandbox.
need_sandbox() {
  valid_name "$1"
  need_sbx
  if is_cloud "$1"; then CLOUD=1; else CLOUD=0; fi
  sandbox_exists "$1" ||
    die "No sandbox named $1 (see boxen ls). Nothing was created; use boxen create $1."
}
# The registry has one line per sandbox: NAME, or NAME<TAB>cloud.
registered() { [[ -f "$REGISTRY" ]] && cut -f1 "$REGISTRY" | grep -Fxq -- "$1"; }
is_cloud() { [[ -f "$REGISTRY" ]] && grep -Fxq -- "$1"$'\t'cloud "$REGISTRY"; }
register() {
  local line="$1"
  if [[ "${2:-}" == cloud ]]; then line="$1"$'\t'cloud; fi
  mkdir -p "$STATE_DIR"
  registered "$1" || printf '%s\n' "$line" >> "$REGISTRY"
}
unregister() {
  [[ -f "$REGISTRY" ]] || return 0
  awk -F'\t' -v name="$1" '$1 != name' "$REGISTRY" > "$REGISTRY.tmp"
  mv "$REGISTRY.tmp" "$REGISTRY"
}
# "NAME STATUS BACKEND" for each sandbox boxen created that still exists. A
# backend that cannot be listed is skipped with a warning, so one unreachable
# service does not stop work on the other.
managed_states() {
  local backend names json
  need_jq "$1"
  [[ -s "$REGISTRY" ]] || return 0
  for backend in local cloud; do
    if [[ "$backend" == cloud ]]; then
      names="$(awk -F'\t' '$2 == "cloud" { print $1 }' "$REGISTRY")"; CLOUD=1
    else
      names="$(awk -F'\t' '$2 != "cloud" { print $1 }' "$REGISTRY")"; CLOUD=0
    fi
    [[ -n "$names" ]] || continue
    if ! json="$(sbx ls --json </dev/null)"; then
      warn "Could not list the $backend sandboxes; skipping them."; continue
    fi
    printf '%s' "$json" | jq -r --arg registry "$names" --arg backend "$backend" '
      ($registry | split("\n") | map(select(length > 0))) as $names
      | .sandboxes[]? | select(.name as $n | $names | index($n)) | "\(.name) \(.status) \($backend)"'
  done
  CLOUD=0
}
has_cloud_rows() { [[ -f "$REGISTRY" ]] && grep -q $'\t'cloud'$' "$REGISTRY"; }
# The cloud id sbx's SSH proxy logs in as.
cloud_id() {
  local json id
  need_jq net
  json="$(sbx ls --json </dev/null)" || die 'sbx ls failed; check boxen doctor.'
  id="$(printf '%s' "$json" | jq -r --arg n "$1" '.sandboxes[]? | select(.name == $n) | .id // .sandbox_id // empty')"
  [[ -n "$id" ]] || die "sbx did not list an id for $1."
  printf '%s\n' "$id"
}
# Root work: --user root locally; Docker's passwordless sudo in the cloud,
# where sbx exec takes no --user. as_root NAME [-i] CMD...
as_root() {
  local name="$1" stdin=()
  shift
  if [[ "${1:-}" == -i ]]; then stdin=(-i); shift; fi
  if [[ "$CLOUD" == 1 ]]; then
    sbx exec ${stdin[@]+"${stdin[@]}"} "$name" sudo -n "$@"
  else
    sbx exec ${stdin[@]+"${stdin[@]}"} --user root "$name" "$@"
  fi
}
refuse_on_cloud() {
  [[ "$CLOUD" == 0 ]] ||
    die "$1 is not supported on cloud sandboxes: cloud secrets cannot run host commands; pipe a token instead"
}
# A stopped cloud sandbox resumes, with a fresh period, on the way in.
resume_if_stopped() {
  local json status
  [[ "$CLOUD" == 1 ]] && command -v jq >/dev/null 2>&1 || return 0
  json="$(sbx ls --json </dev/null)" || return 0
  status="$(printf '%s' "$json" | jq -r --arg n "$1" '.sandboxes[]? | select(.name == $n) | .status')"
  [[ -n "$status" && "$status" != running ]] || return 0
  # On stderr: stdout stays the command's own output, which scripts capture.
  log "Resuming $1" >&2
  sbx run --detached --name "$1" </dev/null >/dev/null || die "Could not resume $1; see sbx --cloud ls."
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
    printf 'boxen: Only %s MiB of memory is available; a %s sandbox needs %s MiB plus 1024 MiB headroom.\n' \
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
created_but() {
  printf 'boxen: Sandbox %s was created, but %s failed.\n' "$1" "$2" >&2
  printf 'Look inside with: boxen shell %s\n' "$1" >&2
  if [[ "$CLOUD" == 1 ]]; then
    printf 'To start over: boxen delete %s, then run create again.\n' "$1" >&2
  else
    printf 'To start over: sbx rm %s, then run create again.\n' "$1" >&2
  fi
  exit 1
}

# --- Credentials -------------------------------------------------------------

# A host-wide sbx secret for SERVICE is injected into every sandbox.
host_wide_secret() {
  local listing
  listing="$(sbx secret ls --global --service "$1" --json 2>/dev/null)" || return 1
  [[ -n "$listing" && "$(printf '%s' "$listing" | tr -d ' \t\n')" != *'"secrets":[]'* ]]
}
# A sandbox-scoped secret for SERVICE. A listing that fails stops here, before
# anything is stored or created.
secret_exists() {
  local listing
  listing="$(sbx secret ls --sandbox "$1" --service "$2" --json </dev/null)" ||
    die "Could not list $1's secrets; nothing was created."
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
    warn "Sign-in did not finish; boxen $1 offers it again."
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

# --- Cloud -------------------------------------------------------------------

# BOXEN_CLOUD_TTL as sbx takes it: sets ttl (8h, 5m), ttl_seconds and
# ttl_words, or dies. Whole hours 1-24 (8 or 8h, default 8) or minutes 5-59.
cloud_ttl() {
  local value="${BOXEN_CLOUD_TTL-8}" n
  if [[ "$value" =~ ^([1-9][0-9]?)h?$ ]] && (( ${BASH_REMATCH[1]} <= 24 )); then
    n="${BASH_REMATCH[1]}"; ttl="${n}h"; ttl_seconds=$((n * 3600))
    if [[ "$n" == 1 ]]; then ttl_words='1 hour'; else ttl_words="$n hours"; fi
  elif [[ "$value" =~ ^([1-9][0-9]?)m$ ]] && (( ${BASH_REMATCH[1]} >= 5 && ${BASH_REMATCH[1]} <= 59 )); then
    n="${BASH_REMATCH[1]}"; ttl="${n}m"; ttl_seconds=$((n * 60)); ttl_words="$n minutes"
  else
    die "$TTL_MESSAGE"
  fi
}
# Reads sbx ttl --json into TTL_LEFT, TTL_ROOM (Docker's creation-based
# ceiling, as seconds from now) and TTL_AT.
read_ttl() {
  local json
  json="$(sbx ttl --json "$1" </dev/null 2>/dev/null)" || return 1
  TTL_LEFT="$(printf '%s' "$json" | jq -r '.expires_in_seconds // empty')"
  TTL_ROOM="$(printf '%s' "$json" | jq -r '.max_remaining_seconds // empty')"
  TTL_AT="$(printf '%s' "$json" | jq -r '.expires_at // empty')"
  [[ "$TTL_LEFT" =~ ^[0-9]+$ && "$TTL_ROOM" =~ ^[0-9]+$ && -n "$TTL_AT" ]]
}
# NAME SECONDS ASKED RUN_RETURNED: after create's own exec steps, compare the
# period the server holds with what is still owed (it starts at creation).
# Extends a short one, never past Docker's ceiling, and reads it back; a
# longer one is reported, since an extension can only lengthen. Sets
# ttl_lines for the end of create and never fails it.
cloud_ttl_report() {
  local name="$1" asked_seconds="$2" since="$3" asked="$4" want add out
  ttl_lines=()
  if ! read_ttl "$name"; then
    ttl_lines=("Could not read the TTL; see sbx --cloud ttl $name")
    warn "${ttl_lines[0]}"
    return 0
  fi
  want=$((asked_seconds - ($(date +%s) - since)))
  if (( TTL_LEFT < want - 60 )); then
    add=$(( (want - TTL_LEFT + 59) / 60 ))
    if (( add > (TTL_ROOM - TTL_LEFT) / 60 )); then add=$(( (TTL_ROOM - TTL_LEFT) / 60 )); fi
    if (( add > 0 )); then
      if out="$(sbx ttl "+${add}m" "$name" </dev/null 2>&1)"; then
        log "TTL came up short; extended by $add minutes"
        read_ttl "$name" || warn "Could not read the TTL back; it was extended by $add minutes."
      else
        warn "Could not extend the TTL: $out"
      fi
    fi
  fi
  ttl_lines=("Stops at $TTL_AT (in $((TTL_LEFT / 3600))h$((TTL_LEFT % 3600 / 60))m; BOXEN_CLOUD_TTL asked for $asked)")
  if (( TTL_LEFT > want + 60 )); then
    ttl_lines+=('Docker set a longer period than asked; it cannot be shortened.')
  fi
}

# Previews from a cloud sandbox are SSH tunnels to 127.0.0.1 on this laptop:
# one background master per sandbox, forwards added and cancelled on it, and
# the list kept in $TUNNEL_STATE/NAME.forwards ("HOST_PORT SANDBOX_PORT"
# lines), recorded only after ssh accepted each one.
ssh_base() {
  ssh_cmd=("$SSH_BIN")
  if [[ -n "${SSH_CONFIG:-}" ]]; then ssh_cmd+=(-F "$SSH_CONFIG"); fi
}
# sbx setup ssh once: until it has run, ssh does not know sbx_cloud's proxy.
ssh_ready() {
  local config
  ssh_base
  config="$("${ssh_cmd[@]}" -G sbx_cloud </dev/null 2>/dev/null || true)"
  case "$config" in *proxycommand*sbx*) return 0 ;; esac
  sbx setup ssh || die 'sbx --cloud setup ssh failed; run it yourself, then boxen net again.'
}
# The master's socket: a private directory of this user's, under TMPDIR
# unless that makes the path too long for a socket (macOS allows 104 bytes).
tunnel_socket() {
  local dir="${TMPDIR:-/tmp}"
  dir="${dir%/}/boxen-tunnels-$UID"
  if (( ${#dir} + ${#1} + 6 > 100 )); then dir="/tmp/boxen-tunnels-$UID"; fi
  (umask 077; mkdir -p "$dir")
  [[ -d "$dir" && ! -L "$dir" && -O "$dir" ]] || die "$dir is not a private directory of yours; remove it and try again."
  chmod 700 "$dir"
  printf '%s/%s.sock\n' "$dir" "$1"
}
# Sets tunnel_id and tunnel_sock from the id recorded when the master opened;
# false when no tunnel was ever opened for NAME.
tunnel_known() {
  [[ -s "$TUNNEL_STATE/$1.id" ]] || return 1
  tunnel_id="$(cat "$TUNNEL_STATE/$1.id")"
  tunnel_sock="$(tunnel_socket "$tunnel_id")"
}
tunnel_up() {
  tunnel_known "$1" || return 1
  ssh_base
  "${ssh_cmd[@]}" -S "$tunnel_sock" -O check "$tunnel_id@sbx_cloud" </dev/null >/dev/null 2>&1
}
# tunnel_master NAME [replay]: opens the master unless it answers. Forwards
# recorded for a master that died are dropped and named, or, with replay
# (boxen net NAME with no ports), requested again on the new one.
tunnel_master() {
  local name="$1" replay="${2:-}" forwards="$TUNNEL_STATE/$1.forwards" stale="" host port
  if tunnel_up "$name"; then return 0; fi
  mkdir -p "$TUNNEL_STATE"
  tunnel_id="$(cloud_id "$name")"
  printf '%s\n' "$tunnel_id" > "$TUNNEL_STATE/$name.id"
  tunnel_sock="$(tunnel_socket "$tunnel_id")"
  ssh_base
  # A live master this registry had lost track of: keep using it.
  if "${ssh_cmd[@]}" -S "$tunnel_sock" -O check "$tunnel_id@sbx_cloud" </dev/null >/dev/null 2>&1; then return 0; fi
  if [[ -s "$forwards" ]]; then stale="$(cat "$forwards")"; fi
  rm -f "$forwards"
  # A master that died uncleanly leaves its socket, and ssh would then start
  # without multiplexing, so every forward would fail.
  rm -f "$tunnel_sock"
  # A file, not a pipe: ssh -f keeps its output open after it forks.
  "${ssh_cmd[@]}" -f -N -M -S "$tunnel_sock" -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 \
    "$tunnel_id@sbx_cloud" </dev/null >/dev/null 2>"$TUNNEL_STATE/$name.ssh.log" || {
    cat "$TUNNEL_STATE/$name.ssh.log" >&2
    die "Could not open an SSH connection to $name; check sbx --cloud ls and sbx --cloud setup ssh."
  }
  [[ -n "$stale" ]] || return 0
  if [[ -n "$replay" ]]; then
    while read -r host port; do
      [[ -n "$host" ]] || continue
      tunnel_forward "$name" "$host" "$port"
    done <<< "$stale"
  else
    warn "The tunnel to $name had closed; these forwards were dropped:"
    while read -r host port; do
      if [[ -n "$host" ]]; then printf '  127.0.0.1:%s -> %s\n' "$host" "$port" >&2; fi
    done <<< "$stale"
  fi
}
tunnel_forward() {
  local name="$1" host="$2" port="$3" forwards="$TUNNEL_STATE/$1.forwards" out
  if [[ -f "$forwards" ]] && awk -v h="$host" '$1 == h { found = 1 } END { exit !found }' "$forwards"; then
    die "127.0.0.1:$host is already forwarded; boxen net $name -r $host first"
  fi
  ssh_base
  if out="$("${ssh_cmd[@]}" -S "$tunnel_sock" -O forward -L "127.0.0.1:$host:127.0.0.1:$port" \
      "$tunnel_id@sbx_cloud" </dev/null 2>&1)"; then
    printf '%s %s\n' "$host" "$port" >> "$forwards"
    log "Forwarded 127.0.0.1:$host to $name's port $port"
  else
    die "Forwarding 127.0.0.1:$host to $name's port $port failed (is the port free on this laptop?): $out"
  fi
}
tunnel_cancel() {
  local name="$1" host="$2" forwards="$TUNNEL_STATE/$1.forwards" port
  port="$(awk -v h="$host" '$1 == h { print $2; exit }' "$forwards" 2>/dev/null || true)"
  [[ -n "$port" ]] || die "127.0.0.1:$host is not forwarded (see boxen net $name -l)"
  if tunnel_up "$name"; then
    ssh_base
    "${ssh_cmd[@]}" -S "$tunnel_sock" -O cancel -L "127.0.0.1:$host:127.0.0.1:$port" \
      "$tunnel_id@sbx_cloud" </dev/null >/dev/null 2>&1 || warn "ssh did not cancel 127.0.0.1:$host; it ends with the tunnel."
  fi
  awk -v h="$host" '$1 != h' "$forwards" > "$forwards.tmp"
  mv "$forwards.tmp" "$forwards"
  log "Removed 127.0.0.1:$host"
}
# Lists the recorded forwards; never opens anything.
tunnel_list() {
  local name="$1" forwards="$TUNNEL_STATE/$1.forwards" host port
  if [[ ! -s "$forwards" ]]; then printf 'No forwards for %s; add one with boxen net %s PORT\n' "$name" "$name"; return; fi
  if ! tunnel_up "$name"; then printf '(tunnel down; boxen net %s to reopen)\n' "$name"; fi
  while read -r host port; do
    if [[ -n "$host" ]]; then printf '127.0.0.1:%s -> %s\n' "$host" "$port"; fi
  done < "$forwards"
}
# Closes the master if there is one and forgets its forwards; never fails.
tunnel_close() {
  if tunnel_known "$1" 2>/dev/null; then
    ssh_base
    "${ssh_cmd[@]}" -S "$tunnel_sock" -O exit "$tunnel_id@sbx_cloud" </dev/null >/dev/null 2>&1 || true
  fi
  rm -f "$TUNNEL_STATE/$1.forwards" "$TUNNEL_STATE/$1.id" "$TUNNEL_STATE/$1.ssh.log"
}
# Sets port_value from a port 1-65535, or dies.
port_number() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )) || die "Not a port: $1"
  port_value=$((10#$1))
}
cloud_net() {
  local name="$1" action=add arg host port port_value re='^([0-9]+)(:([0-9]+))?$' adds=() removes=()
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -b|--bind|-H|--host) die 'cloud previews bind 127.0.0.1 only; share from your laptop with tailscale serve' ;;
      -l|--list) action=list; shift ;;
      -r|--remove)
        need_value "$@"
        [[ "$2" =~ $re ]] || die "Expected PORT or HOST_PORT:SANDBOX_PORT, got $2"
        port_number "${BASH_REMATCH[1]}"; removes+=("$port_value"); shift 2 ;;
      -h|--help) usage; return ;;
      -*) die "Unknown net option: $1" ;;
      supabase)
        for port in $SUPABASE_PORTS; do adds+=("$port $port"); done
        shift ;;
      *)
        [[ "$1" =~ $re ]] || die "Expected PORT, HOST_PORT:SANDBOX_PORT or supabase, got $1"
        # port_number matches too, so take both halves first.
        host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}"
        port_number "$host"; host="$port_value"
        port_number "$port"; port="$port_value"
        adds+=("$host $port"); shift ;;
    esac
  done
  if [[ "$action" == list ]]; then tunnel_list "$name"; return; fi
  for host in ${removes[@]+"${removes[@]}"}; do tunnel_cancel "$name" "$host"; done
  if [[ ${#adds[@]} == 0 ]]; then
    [[ ${#removes[@]} == 0 ]] || return 0
    # No ports: reopen the tunnel with what was recorded, on a running box.
    resume_if_stopped "$name"
    ssh_ready
    tunnel_master "$name" replay
    tunnel_list "$name"
    return
  fi
  # A tunnel needs a running box; listing and removing never start one.
  resume_if_stopped "$name"
  ssh_ready
  tunnel_master "$name"
  for arg in "${adds[@]}"; do
    read -r host port <<< "$arg"
    tunnel_forward "$name" "$host" "$port"
  done
  read -r host port <<< "${adds[0]}"
  printf 'Open http://127.0.0.1:%s on this laptop; the tunnel lasts while this laptop is awake (boxen net %s -l)\n' "$host" "$name"
}

# --- Commands ----------------------------------------------------------------

create() {
  local name="" directory="" agent="" requested="$DEFAULT_PLUGINS" flagged="" mode=""
  local dry=0 ack_env=0 memory="${BOXEN_MEMORY:-4g}" cpus="${BOXEN_CPUS:-}"
  local copy_all=0 skips="" copy_kib=0
  # Nothing from the host is mounted unless asked: no workspace mount, no
  # shared skills store (sbx's own default is a read-only link).
  local skills=off mounts="" tui=1 chose_plugins=0 open_network=0
  local cloud=0 cpus_given=0 memory_given=0 gh_stdin=0 gh_token_stored=0 listing=0
  local ttl="" ttl_seconds=0 ttl_words="" run_returned=0 line
  local gh_token="" op_token="" ts_key="" ts_port="" port_re='^[0-9]+$'
  local selected="" item kit workload identity value home
  local kit_args=() command=() items=() ttl_lines=()
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
      --cloud) cloud=1; shift ;;
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
      --cpus) need_value "$@"; cpus="$2"; cpus_given=1; shift 2 ;;
      --memory) need_value "$@"; memory="$2"; memory_given=1; shift 2 ;;
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
  if [[ "$cloud" == 1 ]]; then
    # Docker's cloud cannot reach this host's directories or skills store.
    case "$mode" in
      mount|clone) die "cloud sandboxes take a copied or empty workspace; --mode $mode shares this host's directory" ;;
    esac
    [[ "$skills" == off ]] || die "--skills shares this host's skills store, which cloud sandboxes cannot reach"
    cloud_ttl
    # The local 4-CPU default is not a cloud shape: Docker's applies unless asked.
    if [[ "$cpus_given" == 0 ]]; then cpus=""; fi
    if [[ "$memory_given" == 0 ]]; then memory=""; fi
  fi
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
    in_list "$item" "$PLUGINS" || die "Unknown plugin: $item (see boxen plugins)"
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
  if [[ "$cloud" == 0 && -z "$cpus" ]]; then
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
  if [[ "$cloud" == 1 ]]; then
    # Cloud create refuses local kits; run composes them. Always stop, never
    # delete, at expiry.
    command=(run --detached --name "$name" --ttl "$ttl" --on-timeout stop)
  else
    command=(create --name "$name" --skills "$skills")
  fi
  if [[ -n "$cpus" ]]; then command+=(--cpus "$cpus"); fi
  if [[ -n "$memory" ]]; then command+=(--memory "$memory"); fi
  command+=(--env "BOXEN_AGENT=$agent" --env "BOXEN_PLUGINS=$selected")
  if [[ "$cloud" == 1 ]]; then command+=(--env BOXEN_CLOUD=1); fi
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
    if [[ "$cloud" == 1 ]]; then
      print_command "$SBX_BIN" --cloud "${command[@]}"
      printf 'Cloud: stops after %s and keeps its files (BOXEN_CLOUD_TTL)\n' "$ttl_words"
    else
      print_command "$SBX_BIN" "${command[@]}"
    fi
    printf 'Workspace: %s%s\n' "$mode" "${directory:+ ($directory)}"
    if [[ "$mode" == copy ]]; then copy_summary "$copy_kib" "$skips"; fi
    printf 'Plugins: %s\n' "${selected:-none}"
    printf 'Host mounts: %s\n' "${mounts:-none}"
    printf 'Start detached, then configure Git identity. No credentials are copied.\n'
    return
  fi
  need_sbx
  need_docker
  CLOUD="$cloud"
  if [[ "$cloud" == 1 ]]; then need_jq 'create --cloud'; fi
  # One name across both backends: the registry, then the selected backend,
  # live. The other backend is never contacted.
  if registered "$name"; then
    if is_cloud "$name"; then die "$name already names a cloud sandbox (see boxen ls)"; fi
    die "$name already names a local sandbox (see boxen ls)"
  fi
  if sandbox_exists "$name"; then
    if [[ "$cloud" == 1 ]]; then
      die "$name already exists in the cloud (not made by boxen); pick another name or remove it with sbx --cloud rm $name"
    fi
    die "$name already exists locally (not made by boxen); pick another name or remove it with sbx rm $name"
  fi
  if [[ "$cloud" == 0 ]]; then memory_ok "$memory" || exit 1; fi
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
  if [[ "$cloud" == 1 ]]; then
    # Stored before the run so the first start has it; create never
    # replaces a credential it did not make.
    if [[ -n "$gh_token" ]]; then
      if secret_exists "$name" github; then
        die "A GitHub secret already exists for $name; create without a token and run boxen auth github $name afterwards, or remove it first with sbx --cloud secret rm --sandbox $name github"
      fi
      printf '%s' "$gh_token" | sbx secret set --sandbox "$name" github || die 'Storing the GitHub token failed; nothing was created.'
      gh_token_stored=1
    fi
    log "Creating $name in Docker Cloud; the first upload of the kits takes a few minutes"
    if ! sbx "${command[@]}" >/dev/null; then
      # The name was free before this attempt, so a sandbox there now (or one
      # that cannot be ruled out) is this attempt's: keep it and its secret.
      listed "$name" || listing=$?
      if [[ "$listing" != 1 ]]; then register "$name" cloud; created_but "$name" 'starting it'; fi
      if [[ "$gh_token_stored" == 1 ]]; then
        sbx secret rm --sandbox "$name" github </dev/null ||
          warn "Removing the GitHub secret failed; remove it with sbx --cloud secret rm --sandbox $name github"
      fi
      die "Creating $name in the cloud failed; nothing was kept."
    fi
    run_returned="$(date +%s)"
    register "$name" cloud
  else
    # sbx create refuses duplicate names. Never remove or recreate an existing sandbox.
    sbx "${command[@]}"
    register "$name"
    # Quiet: it prints only the sandbox ID.
    sbx run --detached --name "$name" >/dev/null || created_but "$name" 'starting it'
  fi
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
    if [[ "$cloud" == 0 ]]; then
      printf '%s' "$gh_token" | sbx secret set --sandbox "$name" github ||
        warn "Storing the GitHub token failed; retry with: boxen auth github $name"
    fi
  elif has_plugin gh-auth; then
    printf 'Add a GitHub token later: boxen auth github %s\n' "$name"
  fi
  if [[ -n "$op_token" ]]; then
    printf 'export OP_SERVICE_ACCOUNT_TOKEN=%q\n' "$op_token" | write_guest_env "$name" OP_SERVICE_ACCOUNT_TOKEN ||
      warn "Storing the 1Password token failed; retry with: boxen env $name OP_SERVICE_ACCOUNT_TOKEN"
  elif has_plugin 1pass; then
    printf 'Add a 1Password token later: boxen env %s OP_SERVICE_ACCOUNT_TOKEN\n' "$name"
  fi
  gh_token="" op_token=""
  if [[ -n "$ts_key" ]]; then
    if printf '%s\n' "$ts_key" | as_root "$name" -i /usr/local/bin/boxen-tailscale join "$name" --auth-key-stdin; then
      if [[ -n "$ts_port" ]]; then
        as_root "$name" /usr/local/bin/boxen-tailscale serve "$ts_port" ||
          warn "Serving port $ts_port failed; retry with: boxen tailscale serve $name $ts_port"
      fi
    else
      warn "Joining the tailnet failed; retry with: boxen tailscale join $name"
    fi
    ts_key=""
  elif has_plugin tailscale; then
    printf 'Join your tailnet: boxen tailscale join %s\n' "$name"
  fi
  if has_plugin tailscale; then
    printf 'Once joined, the sandbox reaches whatever your tailnet ACLs allow, outside sbx network policy.\n'
  fi
  offer_agent_login "$name"
  if [[ "$cloud" == 1 ]]; then cloud_ttl_report "$name" "$ttl_seconds" "$run_returned" "$ttl"; fi
  # Last, after sbx's own "To connect" hint, so this is what stays on screen.
  printf '\nTo open a shell in the sandbox, run:\n  » boxen %s\n' "$name"
  if [[ "$agent" != shell ]]; then printf 'Start the agent with: boxen run %s\n' "$name"; fi
  printf 'Check the plugins with: boxen check %s\n' "$name"
  if [[ "$cloud" == 1 ]]; then
    for line in ${ttl_lines[@]+"${ttl_lines[@]}"}; do printf '%s\n' "$line"; done
    printf 'It stops after %s and keeps its files; resume it with: boxen %s\n' "$ttl_words" "$name"
    printf 'Work lives only in the sandbox until you push it; commit and push often.\n'
    printf 'Preview it on this laptop with: boxen net %s PORT\n' "$name"
  fi
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
  if [[ "$with_sudo" == 1 && "$CLOUD" == 1 ]]; then
    log "cloud sandboxes keep Docker's sudo; sudo is already available in the shell" >&2
    with_sudo=0
  fi
  resume_if_stopped "$name"
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
  resume_if_stopped "$1"
  if [[ -t 0 ]]; then sbx exec "$@"; else sbx exec -i "$@"; fi
}

cmd_stop() {
  [[ $# == 1 ]] || die 'Usage: stop NAME'
  need_sandbox "$1"
  if [[ "$CLOUD" == 1 ]]; then tunnel_close "$1"; fi
  sbx stop "$1"
  log "Stopped $1"
}

cmd_stop_all() {
  local states name status backend stopped=0
  need_sbx
  states="$(managed_states kill-all)"
  while read -r name status backend; do
    [[ -n "$name" ]] || continue
    if [[ "$backend" == cloud ]]; then CLOUD=1; tunnel_close "$name"; else CLOUD=0; fi
    [[ "$status" == running ]] || continue
    sbx stop "$name" </dev/null
    log "Stopped $name"
    stopped=1
  done <<< "$states"
  CLOUD=0
  [[ "$stopped" == 1 ]] || echo 'No running boxen sandboxes'
}

cmd_delete() {
  [[ $# == 1 ]] || die 'Usage: delete NAME'
  need_sandbox "$1"
  if [[ "$CLOUD" == 1 ]]; then tunnel_close "$1"; fi
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
  # A cloud sandbox has no host ports of its own: an SSH tunnel instead.
  if [[ "$CLOUD" == 1 ]]; then cloud_net "$name" "$@"; return; fi
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
    if [[ "$CLOUD" == 1 ]]; then log "Cloud secrets apply when the sandbox next starts: boxen stop $name; boxen $name"; fi
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
  local states name status backend failed="" logfile
  need_sbx
  states="$(managed_states update-all)"
  if [[ -z "$states" ]]; then echo 'No boxen sandboxes found'; return; fi
  mkdir -p "$LOG_DIR"
  logfile="$LOG_DIR/update-$(date +%Y%m%d-%H%M%S).log"
  while read -r name status backend; do
    [[ -n "$name" ]] || continue
    if [[ "$backend" == cloud ]]; then CLOUD=1; else CLOUD=0; fi
    if [[ "$status" != running ]]; then
      # A cloud sandbox runs on Docker's hosts, not in this one's memory.
      if [[ "$CLOUD" == 0 ]] && ! memory_ok "${BOXEN_MEMORY:-4g}"; then failed="$failed $name"; continue; fi
      log "Starting $name..."
      if ! sbx run --detached --name "$name" </dev/null >/dev/null; then failed="$failed $name"; continue; fi
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
  CLOUD=0
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
      line="0 $hour * * * PATH=$(printf '%q' "$PATH") $(printf '%q' "$PROJECT_DIR/boxen") update-all >> $(printf '%q' "$LOG_DIR/cron.log") 2>&1 $CRON_TAG"
      { { crontab -l 2>/dev/null || true; } | { grep -vF "$CRON_TAG" || true; }; printf '%s\n' "$line"; } | crontab -
      log "Installed cron: daily at $(printf '%02d' "$((10#$hour))"):00; logs in $LOG_DIR/cron.log"
      ;;
    remove)
      { crontab -l 2>/dev/null || true; } | { grep -vF "$CRON_TAG" || true; } | crontab -
      log 'Removed the boxen update cron'
      ;;
    status)
      line="$(crontab -l 2>/dev/null | grep -F "$CRON_TAG" || true)"
      if [[ -n "$line" ]]; then echo "Active: $line"; else echo 'No boxen update cron installed'; fi
      ;;
    *) die 'Usage: cron install [HOUR]|remove|status' ;;
  esac
}

# The local list, then the cloud's when boxen made cloud sandboxes.
list_sandboxes() {
  sbx ls "$@"
  has_cloud_rows || return 0
  printf '\nCloud\n'
  CLOUD=1
  sbx ls "$@" || warn 'Could not list the cloud sandboxes.'
  CLOUD=0
}

cmd_status() {
  need_sbx
  case "${1:-}" in
    --once) list_sandboxes ;;
    '') if [[ -t 0 && -t 1 ]]; then sbx tui; else list_sandboxes; fi ;;
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
        refuse_on_cloud 'auth github --from-gh'
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
      refuse_on_cloud 'auth 1password'
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
        as_root "$name" /usr/local/bin/boxen-tailscale join "$name"
      elif [[ $# == 1 && "$1" == --auth-key-stdin ]]; then
        [[ ! -t 0 ]] || die 'Pipe an auth key on stdin; do not pass it as an argument.'
        as_root "$name" -i /usr/local/bin/boxen-tailscale join "$name" --auth-key-stdin
      else die 'Use: tailscale join NAME [--auth-key-stdin]'; fi
      ;;
    status)
      [[ $# == 0 ]] || die 'status accepts only a sandbox name'
      as_root "$name" tailscale status ;;
    serve)
      [[ $# == 1 ]] || die 'Use: tailscale serve NAME PORT|supabase'
      as_root "$name" /usr/local/bin/boxen-tailscale serve "$1" ;;
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
  local version service cloud=0 failed=0
  case "${1:-}" in
    --cloud) cloud=1 ;;
    '') ;;
    *) die 'Usage: doctor [--cloud]' ;;
  esac
  need_sbx
  version="$(sbx version 2>/dev/null | sed -n 's/.*version: v\{0,1\}\([0-9][0-9.]*\).*/\1/p' | head -1)"
  [[ -n "$version" ]] || die 'Could not read the sbx version'
  version_ge "$version" "$MIN_SBX_VERSION" ||
    die "sbx $version is too old; boxen needs $MIN_SBX_VERSION or newer."
  printf 'sbx %s\n' "$version"
  # KVM runs local microVMs; a cloud sandbox runs on Docker's hosts.
  if [[ "$cloud" == 0 && "${BOXEN_SKIP_KVM_CHECK:-0}" != 1 && "$(uname -s)" == Linux ]]; then
    [[ -r /dev/kvm && -w /dev/kvm ]] || die '/dev/kvm is not accessible; local sandboxes need KVM and kvm group membership.'
  fi
  if docker_builder_ok; then
    printf 'Docker builder: ok\n'
  else
    printf 'Docker builder: unavailable (sbx builds local v3 kits with it)\n'; failed=1
  fi
  command -v jq >/dev/null 2>&1 || printf 'Note: kill-all and update-all need jq.\n'
  for service in anthropic openai; do
    if host_wide_secret "$service"; then
      printf 'Note: a host-wide %s secret replaces each sandbox'"'"'s own sign-in (sbx secret rm %s).\n' "$service" "$service"
    fi
  done
  if [[ "$cloud" == 1 ]]; then
    if sbx --cloud ls </dev/null; then printf 'Cloud: ok\n'; else printf 'Cloud: unreachable\n'; failed=1; fi
  else
    sbx ls
  fi
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
    ls) need_sbx; list_sandboxes "$@" ;;
    check)
      [[ $# == 1 ]] || die 'Usage: check NAME'
      need_sandbox "$1"
      resume_if_stopped "$1"
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
