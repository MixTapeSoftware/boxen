#!/usr/bin/env bash
# Runs as root. Docker's images give agent standing passwordless sudo.
# agent-sbx gives none: agent-sbx shell --with-sudo adds the _sudo group to a
# single session through agent-sbx-sudo-session.
set -euo pipefail
groupadd -f _sudo
{
  printf '%%_sudo ALL=(ALL) NOPASSWD: ALL\n'
  # Keep the proxy variables sudo sessions need, as Docker's image does for %sudo.
  if [[ -f /etc/sudoers.d/proxyconfig ]]; then sed 's/%sudo/%_sudo/g' /etc/sudoers.d/proxyconfig; fi
} > /etc/sudoers.d/_sudo
chmod 0440 /etc/sudoers.d/_sudo
for file in /etc/sudoers.d/*; do
  [[ -f "$file" && "$file" != /etc/sudoers.d/_sudo ]] || continue
  if grep -Eq '^[[:space:]]*agent[[:space:]]' "$file"; then rm -f "$file"; fi
done
for group in sudo admin wheel; do
  if id -nG agent | tr ' ' '\n' | grep -qx "$group"; then gpasswd -d agent "$group" >/dev/null; fi
done
# Check only our file: Docker's own proxyconfig is mode 0644, which a full
# visudo -c reports as an error although sudo reads it.
visudo -cqf /etc/sudoers.d/_sudo
install -m 755 /home/agent/.local/share/agent-sbx/sudo-session.sh /usr/local/bin/agent-sbx-sudo-session
# Fail creation rather than leave the agent with standing root.
if sudo -l -U agent 2>/dev/null | grep -q 'may run'; then
  echo 'agent still has sudo after removing it; inspect /etc/sudoers and /etc/sudoers.d' >&2
  exit 1
fi
