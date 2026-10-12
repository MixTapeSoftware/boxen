# Sourced by agent-sbx. Interactive kit selector for create.
# Reads and sets the caller's $agent and $selected (a comma list), so flags
# and defaults arrive pre-selected. Bash 3.2 compatible.

tui_select() {
  local ids=() descs=() kinds=() marks=() id desc i count cursor=0 key seq mark
  local first_plugin keep_docker=""
  # One agent per sandbox: a pick-one group above the plugin checkboxes.
  ids=(shell claude codex grok)
  descs=('No coding agent; a zsh workload' 'Claude Code' 'Codex' 'Grok Build')
  kinds=(agent agent agent agent)
  first_plugin=${#ids[@]}
  while IFS=$'\t' read -r id desc; do
    # Docker is native to every sandbox; there is nothing to choose.
    [[ "$id" != docker ]] || continue
    ids+=("$id"); descs+=("$desc"); kinds+=(plugin)
  done < <(tail -n +2 "$PROJECT_DIR/plugins.tsv")
  count=${#ids[@]}
  for ((i = 0; i < count; i++)); do
    if [[ "${kinds[i]}" == agent ]]; then
      if [[ "${ids[i]}" == "$agent" ]]; then marks[i]=1; cursor=$i; else marks[i]=0; fi
    elif has_plugin "${ids[i]}"; then marks[i]=1
    else marks[i]=0; fi
  done
  if has_plugin docker; then keep_docker=docker; fi

  tput civis 2>/dev/null || true
  while true; do
    printf '\033[2J\033[H'
    printf '  Create %s: choose an agent and kits\n' "$name"
    printf '  Up/Down or j/k: move   Space: choose   Enter: create   q: quit\n\n'
    printf '  Agent (one per sandbox)\n'
    for ((i = 0; i < count; i++)); do
      if [[ $i == "$first_plugin" ]]; then printf '\n  Kits\n'; fi
      if [[ "${kinds[i]}" == agent ]]; then
        if [[ "${marks[i]}" == 1 ]]; then mark='(*)'; else mark='( )'; fi
      else
        if [[ "${marks[i]}" == 1 ]]; then mark='[x]'; else mark='[ ]'; fi
      fi
      if [[ $i == "$cursor" ]]; then
        printf '  \033[7m %s %-20s %s \033[0m\n' "$mark" "${ids[i]}" "${descs[i]}"
      else
        printf '   %s %-20s %s\n' "$mark" "${ids[i]}" "${descs[i]}"
      fi
    done
    printf '\n  Core tools and Docker are always included.\n'

    IFS= read -rsn1 key || key=q
    case "$key" in
      $'\x1b')
        IFS= read -rsn2 -t 1 seq || continue
        case "$seq" in
          '[A') cursor=$(( (cursor - 1 + count) % count )) ;;
          '[B') cursor=$(( (cursor + 1) % count )) ;;
        esac ;;
      k) cursor=$(( (cursor - 1 + count) % count )) ;;
      j) cursor=$(( (cursor + 1) % count )) ;;
      ' ')
        if [[ "${kinds[cursor]}" == agent ]]; then
          for ((i = 0; i < first_plugin; i++)); do marks[i]=0; done
          marks[cursor]=1
        elif [[ "${marks[cursor]}" == 1 ]]; then marks[cursor]=0
        else marks[cursor]=1; fi ;;
      ''|$'\n') break ;;
      q|Q)
        tput cnorm 2>/dev/null || true
        printf '\033[2J\033[H'
        die 'Aborted; nothing was created.' ;;
    esac
  done
  tput cnorm 2>/dev/null || true
  printf '\033[2J\033[H'

  selected="$keep_docker"
  for ((i = 0; i < count; i++)); do
    [[ "${marks[i]}" == 1 ]] || continue
    if [[ "${kinds[i]}" == agent ]]; then agent="${ids[i]}"; else add_plugin "${ids[i]}"; fi
  done
}
