#!/usr/bin/env bash
# Runs as root. Docker's images give agent standing passwordless sudo.
# boxen gives none: boxen shell --with-sudo adds the _sudo group to a
# single session through boxen-sudo-session. Runs as a root install hook at
# create, so the image itself ships Docker's groups and sudoers untouched.
set -euo pipefail
# Proof means sudo itself saying agent is not allowed. A sudo that fails,
# or prints anything else, is not proof, and creation stops.
verify() {
  local report
  report="$(sudo -l -U agent 2>&1)" || true
  if [[ "$report" == *"is not allowed to run sudo"* ]]; then return 0; fi
  printf 'agent may still have sudo; sudo -l -U agent said:\n%s\ninspect /etc/sudoers and /etc/sudoers.d\n' "${report:-<nothing>}" >&2
  return 1
}
if [[ "${1:-}" == verify ]]; then verify; exit; fi
if [[ "${BOXEN_CLOUD:-0}" == 1 ]]; then echo "boxen: cloud sandbox, keeping Docker's sudo for the agent"; exit 0; fi
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
install -m 755 /usr/local/share/boxen/sudo-session.sh /usr/local/bin/boxen-sudo-session
# Fail creation rather than leave the agent with standing root.
verify
