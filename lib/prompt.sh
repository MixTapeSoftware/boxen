# Sourced by boxen. Reading pasted values from a terminal.
#
# Terminals can wrap a paste in escape sequences the user never sees: focus
# reports (ESC [ O, ESC [ I) and bracketed paste (ESC [ 200~ ... ESC [ 201~).
# `read` keeps all of it, so a token saved as read fails later with a bare 401.
# Kept compatible with Bash 3.2 and BSD sed.

# Drop terminal escape sequences and control characters, then trim spaces.
clean_pasted_value() {
  LC_ALL=C sed -e $'s|\e\\[[0-?]*[ -/]*[@-~]||g' \
    | LC_ALL=C tr -d '\000-\037\177' \
    | sed -e 's/^ *//' -e 's/ *$//'
}

# read_secret VAR PROMPT: hidden input, cleaned; empty at end of input.
read_secret() {
  local _rs_var="$1" _rs_prompt="$2" _rs_raw=""
  IFS= read -rsp "$_rs_prompt" _rs_raw || true
  # Hidden input does not echo the Enter key.
  if [[ -t 0 ]]; then echo "" >&2; fi
  printf -v "$_rs_var" '%s' "$(printf '%s' "$_rs_raw" | clean_pasted_value)"
}

# read_value VAR PROMPT: like read_secret, but the input is shown.
read_value() {
  local _rv_var="$1" _rv_prompt="$2" _rv_raw=""
  IFS= read -rp "$_rv_prompt" _rv_raw || true
  printf -v "$_rv_var" '%s' "$(printf '%s' "$_rv_raw" | clean_pasted_value)"
}
