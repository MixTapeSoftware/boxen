# Used by Bash and zsh.
alias f="fzf --preview 'bat --color=always -- {}'"
# gdiff [GIT DIFF OPTIONS...] [-- PATHS...]: pick changed files with a diff
# preview. Options go before --name-only's paths; the preview keeps only the
# options, since fzf passes it the file.
gdiff() {
  # Quote the preview arguments for fzf's child shell.
  local arg preview='git diff'
  for arg in "$@"; do
    [[ "$arg" == -- ]] && break
    printf -v arg '%q' "$arg"; preview="$preview $arg"
  done
  git diff --name-only "$@" | fzf -m --ansi --preview "$preview --color=always -- {}"
}
