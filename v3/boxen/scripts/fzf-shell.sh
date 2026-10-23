# Used by Bash and zsh.
alias f="fzf --preview 'bat --color=always -- {}'"
gdiff() {
  # Quote the preview arguments for fzf's child shell.
  local arg preview='git diff'
  for arg in "$@"; do printf -v arg '%q' "$arg"; preview="$preview $arg"; done
  git diff "$@" --name-only | fzf -m --ansi --preview "$preview --color=always -- {}"
}
