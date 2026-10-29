#!/usr/bin/env bash
# Base provisioning, as the Sprite's user: mise's Node and Go, Oh My Zsh, and
# the shell files that load Boxen's environment.
set -euo pipefail
source /etc/boxen/env.sh
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
# Every zsh reads .zshenv, interactive or not, so bxn env's variables reach
# the agent and every command it runs.
if ! grep -qF '# boxen env' "$HOME/.zshenv" 2>/dev/null; then
  printf '# boxen env\n[[ ! -r /etc/boxen/env.sh ]] || source /etc/boxen/env.sh\n' >> "$HOME/.zshenv"
fi
if ! grep -qF '# boxen shell' "$HOME/.zshrc" 2>/dev/null; then
  cat >> "$HOME/.zshrc" <<'ZSHRC'
# boxen shell
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME=dpoggi
plugins=(git zsh-autosuggestions)
source "$ZSH/oh-my-zsh.sh"
eval "$(mise activate zsh)"
PROMPT="%F{cyan}[sprite]%f $PROMPT"
[[ ! -f /usr/local/share/boxen/fzf-shell.sh ]] || source /usr/local/share/boxen/fzf-shell.sh
ZSHRC
fi
for file in .bashrc .profile; do
  if ! grep -qF '# boxen env' "$HOME/$file" 2>/dev/null; then
    printf '# boxen env\n[ ! -r /etc/boxen/env.sh ] || . /etc/boxen/env.sh\n' >> "$HOME/$file"
  fi
done
if ! grep -qF '# boxen interactive bash' "$HOME/.bashrc"; then
  cat >> "$HOME/.bashrc" <<'BASHRC'
# boxen interactive bash
eval "$(mise activate bash)"
[[ ! -f /usr/local/share/boxen/fzf-shell.sh ]] || source /usr/local/share/boxen/fzf-shell.sh
BASHRC
fi
