# Boxen's environment in a Sprite: sourced by ~/.zshenv, ~/.bashrc and
# ~/.profile, and by every guest script. Installed as /etc/boxen/env.sh.
boxen_path_prepend() { case ":$PATH:" in *":$1:"*) ;; *) PATH="$1:$PATH" ;; esac; }
boxen_path_prepend "$HOME/.cubic/bin"
boxen_path_prepend "$HOME/.local/share/mise/shims"
boxen_path_prepend "$HOME/.local/bin"
export PATH
export MISE_GIX=false
# gh stack is pinned, so its upgrade notices would only ask for an upgrade gh
# refuses.
export GH_STACK_NO_UPDATE_NOTIFIER=1
# Trust mise config anywhere in the workspace, including repositories cloned
# there after setup, so mise never stops to ask for mise trust.
export MISE_TRUSTED_CONFIG_PATHS="$HOME/workspace:/workspace"
export npm_config_prefix="$HOME/.local"
case ":${NODE_PATH:-}:" in *":$HOME/.local/lib/node_modules:"*) ;; *) export NODE_PATH="$HOME/.local/lib/node_modules${NODE_PATH:+:$NODE_PATH}" ;; esac
# The agent and plugins chosen at create, written by bxn as root.
if [ -r /etc/boxen/sprite.env ]; then . /etc/boxen/sprite.env; fi
# Variables set with bxn env; reread on every source so changes land.
if [ -r "$HOME/.config/boxen/env.sh" ]; then . "$HOME/.config/boxen/env.sh"; fi
