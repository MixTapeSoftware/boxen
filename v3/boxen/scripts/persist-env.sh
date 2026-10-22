#!/bin/sh
# Claude's CLAUDE_ENV_FILE is /etc/sandbox-persistent.sh, which sbx owns.
# Append one sourcing line so agent tool calls see Boxen's PATH.
set -eu
file="${BOXEN_PERSISTENT_FILE:-/etc/sandbox-persistent.sh}"
touch "$file"
grep -qF '/etc/boxen/env.sh' "$file" || printf '. /etc/boxen/env.sh\n' >> "$file"
