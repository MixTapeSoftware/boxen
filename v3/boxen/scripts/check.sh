#!/usr/bin/env bash
set -uo pipefail
source /etc/boxen/env.sh
failed=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then printf 'PASS %s\n' "$label"
  else printf 'FAIL %s\n' "$label"; failed=1; fi
}
selected=",${BOXEN_PLUGINS:-},"
check mise mise --version
check Node node --version
check Go go version
check zsh zsh --version
check 'GitHub CLI' gh --version
check 'Docker CLI' docker --version
check Compose docker compose version
if [[ "${BOXEN_CLOUD:-0}" == 1 ]]; then
  check "Docker's sudo (cloud sandbox)" sudo -n true
else
  check 'No standing sudo' bash -c '! sudo -n true'
fi
for pair in 'fzf-bat:fzf' 'fzf-bat:bat' 'just:just' 'glow:glow' \
  'mermaid-ascii:mermaid-ascii' 'overmind:overmind' 'rtkplus:rtk' \
  'nvchad:nvim' '1pass:op' 'tailscale:tailscale'; do
  plugin="${pair%%:*}"; binary="${pair#*:}"
  [[ "$selected" != *",$plugin,"* ]] || check "$binary" command -v "$binary"
done
if [[ "$selected" == *,cubic,* ]]; then check cubic test -x "$HOME/.cubic/bin/cubic"; fi
if [[ "$selected" == *,chromium,* ]]; then
  check Playwright playwright --version
  check Chrome google-chrome --version
  check ChromeDriver chromedriver --version
  check 'Browser launch' node -e 'const {chromium}=require("playwright"); (async()=>{const b=await chromium.launch();const p=await b.newPage();await p.setContent("<title>boxen</title>");if(await p.title()!=="boxen")throw Error("title");await b.close()})().catch(e=>{console.error(e);process.exit(1)})'
  check 'ChromeDriver session' python3 /usr/local/share/boxen/browser-check.py
fi
if [[ "$selected" == *,nvchad,* ]]; then
  check 'nvChad config' test -f "$HOME/.config/nvim/lua/chadrc.lua"
  check 'nvChad plugins' nvim --headless -c "luafile /usr/local/share/boxen/lazy-check.lua" -c qa
  for lsp in lua-language-server gopls pyright-langserver typescript-language-server \
    bash-language-server elixir-ls; do
    check "Mason $lsp" test -x "$HOME/.local/share/nvim/mason/bin/$lsp"
  done
fi
if [[ "$selected" == *,rtkplus,* ]]; then check 'Codex RTK hooks' test -f "$HOME/.codex/hooks.json"; fi
if [[ "$selected" == *,tailscale,* ]]; then
  check 'Tailscale daemon socket' test -S /var/run/tailscale/tailscaled.sock
  printf 'INFO Tailnet login and HTTPS routes require a separate authenticated check.\n'
fi
case "${BOXEN_AGENT:-shell}" in
  shell) ;;
  claude|codex|grok) check "$BOXEN_AGENT" command -v "$BOXEN_AGENT" ;;
  *) printf 'FAIL agent %s is not one boxen knows\n' "$BOXEN_AGENT"; failed=1 ;;
esac
exit "$failed"
