# boxen environment: sourced by login shells and by CLAUDE_ENV_FILE.
boxen_path_prepend() { case ":$PATH:" in *":$1:"*) ;; *) PATH="$1:$PATH" ;; esac; }
boxen_path_prepend "$HOME/.cubic/bin"
boxen_path_prepend "$HOME/.local/share/mise/shims"
boxen_path_prepend "$HOME/.local/bin"
export PATH
export MISE_GIX=false
export npm_config_prefix="$HOME/.local"
case ":${NODE_PATH:-}:" in *":$HOME/.local/lib/node_modules:"*) ;; *) export NODE_PATH="$HOME/.local/lib/node_modules${NODE_PATH:+:$NODE_PATH}" ;; esac
if [ -n "${HTTP_PROXY:-}" ]; then
  export npm_config_proxy="$HTTP_PROXY"
  export npm_config_https_proxy="${HTTPS_PROXY:-$HTTP_PROXY}"
fi
# Variables set with boxen env; reread on every source so changes land.
if [ -r "$HOME/.config/boxen/env.sh" ]; then . "$HOME/.config/boxen/env.sh"; fi
