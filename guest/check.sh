#!/usr/bin/env bash
# bxn check NAME: the base tools, then each plugin chosen at create.
set -uo pipefail
source /etc/boxen/env.sh
failed=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then printf 'PASS %s\n' "$label"
  else printf 'FAIL %s\n' "$label"; failed=1; fi
}
has() { [[ ",${BOXEN_PLUGINS:-}," == *",$1,"* ]]; }
check mise mise --version
check Node node --version
check Go go version
check zsh zsh --version
check 'GitHub CLI' gh --version
check 'Workspace' test -d /workspace
if has gh-auth; then check 'Git uses gh for GitHub' sh -c 'git config --global --get credential.https://github.com.helper | grep -q "gh auth git-credential"'; fi
if has gh-stack; then
  check 'gh stack' gh stack --version
  check 'gh-stack skill' test -f "$HOME/.claude/skills/gh-stack/SKILL.md"
fi
if has skills; then
  check 'botfight skill for Claude Code' test -f "$HOME/.claude/skills/botfight/SKILL.md"
  check 'botfight skill for Codex and Grok' test -f "$HOME/.agents/skills/botfight/SKILL.md"
fi
if has fzf-bat; then check fzf command -v fzf; check bat command -v bat; fi
for tool in just glow mermaid-ascii overmind; do
  if has "$tool"; then check "$tool" command -v "$tool"; fi
done
if has 1pass; then check op command -v op; fi
if has cubic; then check cubic test -x "$HOME/.cubic/bin/cubic"; fi
if has rtkplus; then
  check rtk command -v rtk
  case "${BOXEN_AGENT:-shell}" in
    claude) check 'Claude RTK hook' jq -e '[.hooks.PreToolUse[]?.hooks[]? | select(.command == "rtk hook claude")] | length == 1' "$HOME/.claude/settings.json" ;;
    codex) check 'Codex RTK hooks' test -f "$HOME/.codex/hooks.json" ;;
  esac
fi
if has chromium; then
  check Playwright playwright --version
  check Chrome google-chrome --version
  check ChromeDriver chromedriver --version
  check 'Browser launch' node -e 'const {chromium}=require("playwright"); (async()=>{const b=await chromium.launch();const p=await b.newPage();await p.setContent("<title>boxen</title>");if(await p.title()!=="boxen")throw Error("title");await b.close()})().catch(e=>{console.error(e);process.exit(1)})'
  check 'ChromeDriver session' python3 /usr/local/share/boxen/browser-check.py
fi
if has nvchad; then
  check 'nvChad config' test -f "$HOME/.config/nvim/lua/chadrc.lua"
  check 'nvChad plugins' nvim --headless -c "luafile /usr/local/share/boxen/lazy-check.lua" -c qa
  for lsp in lua-language-server gopls pyright-langserver typescript-language-server \
    bash-language-server elixir-ls; do
    check "Mason $lsp" test -x "$HOME/.local/share/nvim/mason/bin/$lsp"
  done
fi
if has docker; then
  check 'Docker daemon' docker info
  check Compose docker compose version
fi
case "${BOXEN_AGENT:-shell}" in
  shell) ;;
  claude|codex|grok) check "$BOXEN_AGENT" command -v "$BOXEN_AGENT" ;;
  *) printf 'FAIL agent %s is not one boxen knows\n' "$BOXEN_AGENT"; failed=1 ;;
esac
exit "$failed"
