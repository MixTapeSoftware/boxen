#!/usr/bin/env bash
set -euo pipefail
source /etc/sandbox-persistent.sh
mkdir -p "$HOME/.local/bin" "$HOME/.config/mise"
mise settings set gix false
mise use --global node@22 go@1.27.2
if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
  git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh"
fi
if [[ ! -d "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions" ]]; then
  git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions.git \
    "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions"
fi
if ! grep -qF '# boxen shell' "$HOME/.zshrc" 2>/dev/null; then
  cat >> "$HOME/.zshrc" <<'EOF'
# boxen shell
source /etc/sandbox-persistent.sh
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME=dpoggi
plugins=(git zsh-autosuggestions)
source "$ZSH/oh-my-zsh.sh"
eval "$(mise activate zsh)"
PROMPT="%F{cyan}[sbx]%f $PROMPT"
[[ ! -f "$HOME/.local/share/boxen/fzf-shell.sh" ]] || source "$HOME/.local/share/boxen/fzf-shell.sh"
EOF
fi
if ! grep -qF '# boxen interactive bash' "$HOME/.bashrc"; then
  cat >> "$HOME/.bashrc" <<'EOF'
# boxen interactive bash
source /etc/sandbox-persistent.sh
eval "$(mise activate bash)"
[[ ! -f "$HOME/.local/share/boxen/fzf-shell.sh" ]] || source "$HOME/.local/share/boxen/fzf-shell.sh"
EOF
fi
