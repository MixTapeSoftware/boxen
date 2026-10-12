#!/usr/bin/env bash
set -euo pipefail
source /etc/sandbox-persistent.sh
nvim_version=v0.12.6
case "$(uname -m)" in
  x86_64) arch=x86_64; checksum=474430d53e6264f6d6dd18db42d6dc9df3a1b56ca9e88a325bbf860e1a811d87 ;;
  aarch64|arm64) arch=arm64; checksum=8f1f64a0bdb97247034038c3823c6cbad5bdf9ecd5751b85494b71c3ee04c815 ;;
  *) echo 'Unsupported Neovim architecture' >&2; exit 1 ;;
esac
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "https://github.com/neovim/neovim/releases/download/$nvim_version/nvim-linux-$arch.tar.gz" -o "$tmp/nvim.tar.gz"
printf '%s  %s\n' "$checksum" "$tmp/nvim.tar.gz" | sha256sum -c --quiet -
mkdir -p "$HOME/.local/opt/nvim"
tar -C "$HOME/.local/opt/nvim" --strip-components=1 -xzf "$tmp/nvim.tar.gz"
ln -sfn "$HOME/.local/opt/nvim/bin/nvim" "$HOME/.local/bin/nvim"
revision=c0e1543a7a64c8db877df02fc7decfb0a9e07ecb
git clone https://github.com/chadfennell/nvChad.git "$tmp/config"
git -C "$tmp/config" checkout --detach "$revision"
mkdir -p "$HOME/.config"
if [[ -e "$HOME/.config/nvim" || -L "$HOME/.config/nvim" ]]; then
  backup="$(mktemp -d "$HOME/.config/nvim.backup.XXXXXX")"
  mv "$HOME/.config/nvim" "$backup/nvim"
fi
mv "$tmp/config" "$HOME/.config/nvim"
npm install --global tree-sitter-cli@0.27.1
nvim --headless '+Lazy! sync' +qa
# Lazy reports clone failures but still exits 0; fail creation instead.
nvim --headless -c "luafile $HOME/.local/share/agbx/lazy-check.lua" -c qa
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
nvim --headless -c "luafile $tmp/parsers.lua" -c qa
nvim --headless -c 'MasonInstall lua-language-server gopls pyright typescript-language-server bash-language-server elixir-ls' -c qa
