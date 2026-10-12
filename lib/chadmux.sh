# Sourced by install. Chadmux, Chad's opinionated tmux config, on the host.
# An existing host tmux config is never moved, replaced, or linked over.
# Bash 3.2 compatible; the caller defines log, warn and die.

CHADMUX_UPSTREAM="https://github.com/chadfennell/chadmux.git"
TPM_UPSTREAM="https://github.com/tmux-plugins/tpm"
# Chadmux's tmux.conf refers to ~/.config/tmux by path, so install there
# regardless of XDG_CONFIG_HOME.
CHADMUX_DIR="$HOME/.config/tmux"
CHADMUX_LEGACY_CONF="$HOME/.tmux.conf"
TPM_DIR="$HOME/.tmux/plugins/tpm"

# Every user config location tmux reads.
chadmux_config_paths() {
  echo "$CHADMUX_LEGACY_CONF"
  echo "$CHADMUX_DIR"
  if [[ -n "${XDG_CONFIG_HOME:-}" && "$XDG_CONFIG_HOME/tmux" != "$CHADMUX_DIR" ]]; then
    echo "$XDG_CONFIG_HOME/tmux"
  fi
}

# The Chadmux checkout and legacy link are in place (TPM may still be missing).
chadmux_config_installed() {
  local origin
  [[ -d "$CHADMUX_DIR/.git" ]] || return 1
  origin="$(git -C "$CHADMUX_DIR" config --get remote.origin.url 2>/dev/null || true)"
  [[ "$origin" == "$CHADMUX_UPSTREAM" || "$origin" == "${CHADMUX_UPSTREAM%.git}" ]] || return 1
  [[ -L "$CHADMUX_LEGACY_CONF" && "$CHADMUX_LEGACY_CONF" -ef "$CHADMUX_DIR/tmux.conf" ]]
}

# Prints: installed | incomplete | existing PATH | missing COMMAND | absent
chadmux_status() {
  local cmd path
  if command -v git >/dev/null 2>&1 && chadmux_config_installed; then
    # Incomplete: a TPM clone failed after the config was linked. Installing
    # again finishes the TPM step without touching the config.
    if [[ -x "$TPM_DIR/bin/install_plugins" ]]; then echo installed; else echo incomplete; fi
    return
  fi
  while IFS= read -r path; do
    if [[ -e "$path" || -L "$path" ]]; then
      echo "existing $path"
      return
    fi
  done < <(chadmux_config_paths)
  for cmd in git tmux; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "missing $cmd"
      return
    fi
  done
  echo absent
}

chadmux_install_config() {
  log "Installing Chadmux from chadfennell/chadmux..."
  mkdir -p "$HOME/.config"
  # Finish downloading before creating anything tmux would read. Global, not
  # local: the EXIT trap runs after this function has returned.
  chadmux_staging="$(mktemp -d "$HOME/.config/.chadmux.XXXXXX")"
  trap 'rm -rf "$chadmux_staging"' EXIT
  git clone --depth 1 --branch main "$CHADMUX_UPSTREAM" "$chadmux_staging"

  # mkdir and ln -s both fail rather than replace, so a config created since
  # the status check is never written into or linked over.
  mkdir "$CHADMUX_DIR" 2>/dev/null || die "$CHADMUX_DIR appeared during installation; leaving it alone"
  trap 'rm -rf "$chadmux_staging" "$CHADMUX_DIR"' EXIT
  (shopt -s dotglob && mv "$chadmux_staging"/* "$CHADMUX_DIR"/)
  ln -s "$CHADMUX_DIR/tmux.conf" "$CHADMUX_LEGACY_CONF" 2>/dev/null ||
    die "$CHADMUX_LEGACY_CONF appeared during installation; leaving it alone"
  trap 'rm -rf "$chadmux_staging"' EXIT
  log "Linked $CHADMUX_LEGACY_CONF -> $CHADMUX_DIR/tmux.conf"
}

chadmux_install() {
  local state
  state="$(chadmux_status)"
  case "$state" in
    absent) chadmux_install_config ;;
    incomplete) log 'Chadmux config is in place; finishing TPM setup' ;;
    installed) log 'Chadmux is already installed on this host'; return 0 ;;
    existing\ *) die "Found an existing tmux config at ${state#existing }; leaving it alone" ;;
    missing\ *) die "Chadmux needs ${state#missing } on the host" ;;
  esac

  if [[ ! -d "$TPM_DIR" ]]; then
    log 'Cloning TPM...'
    mkdir -p "${TPM_DIR%/*}"
    git clone --depth 1 "$TPM_UPSTREAM" "$TPM_DIR" ||
      die 'TPM clone failed; the Chadmux config is installed. Run ./install --chadmux again to finish.'
  fi

  log 'Installing TPM plugins...'
  "$TPM_DIR/bin/install_plugins" ||
    warn 'TPM plugin install returned non-zero; press prefix + I inside tmux to retry'
  log 'Chadmux installed. Start tmux, or reload a running server with: tmux source-file ~/.tmux.conf'
}
