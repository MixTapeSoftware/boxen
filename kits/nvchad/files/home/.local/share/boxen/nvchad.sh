#!/usr/bin/env bash
set -euo pipefail
source /etc/sandbox-persistent.sh
# Every network or build step is named and time-limited, so a stall fails
# creation with the step's name instead of spinning forever. Nothing reads
# stdin: a background process reading a terminal would stop, not time out.
step() {
  local name="$1" minutes="$2" status=0
  shift 2
  printf '\nnvchad: %s\n' "$name" >&2
  timeout --kill-after=30 "$((minutes * 60))" "$@" </dev/null || status=$?
  case "$status" in
    0) return 0 ;;
    124|137) printf '\nnvchad: %s timed out after %s min\n' "$name" "$minutes" >&2 ;;
    *) printf '\nnvchad: %s failed (exit %s)\n' "$name" "$status" >&2 ;;
  esac
  return "$status"
}
nvim_version=v0.12.6
case "$(uname -m)" in
  x86_64) arch=x86_64; checksum=474430d53e6264f6d6dd18db42d6dc9df3a1b56ca9e88a325bbf860e1a811d87 ;;
  aarch64|arm64) arch=arm64; checksum=8f1f64a0bdb97247034038c3823c6cbad5bdf9ecd5751b85494b71c3ee04c815 ;;
  *) echo 'Unsupported Neovim architecture' >&2; exit 1 ;;
esac
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
step 'download Neovim' 5 \
  curl -fsSL "https://github.com/neovim/neovim/releases/download/$nvim_version/nvim-linux-$arch.tar.gz" -o "$tmp/nvim.tar.gz"
printf '%s  %s\n' "$checksum" "$tmp/nvim.tar.gz" | sha256sum -c --quiet -
mkdir -p "$HOME/.local/opt/nvim"
tar -C "$HOME/.local/opt/nvim" --strip-components=1 -xzf "$tmp/nvim.tar.gz"
ln -sfn "$HOME/.local/opt/nvim/bin/nvim" "$HOME/.local/bin/nvim"
revision=c0e1543a7a64c8db877df02fc7decfb0a9e07ecb
step 'clone the nvChad config' 5 git clone https://github.com/chadfennell/nvChad.git "$tmp/config"
git -C "$tmp/config" checkout --detach "$revision"
mkdir -p "$HOME/.config"
if [[ -e "$HOME/.config/nvim" || -L "$HOME/.config/nvim" ]]; then
  backup="$(mktemp -d "$HOME/.config/nvim.backup.XXXXXX")"
  mv "$HOME/.config/nvim" "$backup/nvim"
fi
mv "$tmp/config" "$HOME/.config/nvim"
step 'install tree-sitter-cli' 5 npm install --global tree-sitter-cli@0.27.1
step 'sync plugins' 10 nvim --headless '+Lazy! sync' +qa
# Lazy reports clone failures but still exits 0; fail creation instead.
step 'check plugins' 2 nvim --headless -c "luafile $HOME/.local/share/boxen/lazy-check.lua" -c qa
cat > "$tmp/parsers.lua" <<'EOF'
local ok, err = pcall(function()
  require('lazy').load({ plugins = { 'nvim-treesitter' } })
  local treesitter = require('nvim-treesitter')
  if treesitter.install then
    assert(treesitter.install({ 'lua', 'go', 'python', 'typescript', 'bash', 'elixir' }):wait(300000))
  else
    vim.cmd('TSInstallSync lua go python typescript bash elixir')
  end
end)
if not ok then
  io.stderr:write(tostring(err) .. '\n')
  vim.cmd('cquit 1')
end
EOF
step 'compile tree-sitter parsers' 10 nvim --headless -c "luafile $tmp/parsers.lua" -c qa
step 'install language servers' 15 nvim --headless \
  -c 'MasonInstall lua-language-server gopls pyright typescript-language-server bash-language-server elixir-ls' -c qa
# MasonInstall reports failures (and Go's ordinary download messages) as
# errors but still exits 0, so look for the binaries instead.
missing=""
for lsp in lua-language-server gopls pyright-langserver typescript-language-server \
  bash-language-server elixir-ls; do
  [[ -x "$HOME/.local/share/nvim/mason/bin/$lsp" ]] || missing="$missing $lsp"
done
if [[ -n "$missing" ]]; then
  echo "nvchad: Mason did not install:$missing" >&2
  exit 1
fi
