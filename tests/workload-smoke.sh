#!/usr/bin/env bash
# One disposable, memory-capped v3 sandbox made through ./boxen; no model
# calls or personal keys. The second argument picks RTK (the default) or not:
# shell and Grok with rtk exercise the "RTK not added for this agent" path.
set -euo pipefail
[[ $# == 1 || $# == 2 ]] || { echo "Usage: $0 shell|claude|codex|grok [rtk|nortk]" >&2; exit 2; }
agent="$1"
rtk="${2:-rtk}"
case "$agent" in shell|claude|codex|grok) ;; *) echo 'Unknown agent' >&2; exit 2 ;; esac
case "$rtk" in
  rtk) plugins=rtkplus,gh-auth ;;
  nortk) plugins=gh-auth ;;
  *) echo 'The second argument is rtk or nortk' >&2; exit 2 ;;
esac
project="$(cd "$(dirname "$0")/.." && pwd)"
sbx_bin="${SBX_BIN:-sbx}"
docker_bin="${DOCKER_BIN:-docker}"
logs="$project/local/validation"
mkdir -p "$logs"
# Refuse concurrent smoke runs, including on hosts with plenty of RAM. A lock
# whose process is gone (host restart, OOM kill) is reclaimed.
lock="$logs/.workload-lock"
if ! mkdir "$lock" 2>/dev/null; then
  holder="$(cat "$lock/pid" 2>/dev/null || true)"
  if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
    echo "Another workload check (PID $holder) holds $lock" >&2
    exit 1
  fi
  echo "Reclaiming stale lock $lock" >&2
  rm -rf "$lock"
  mkdir "$lock"
fi
printf '%s\n' "$$" > "$lock/pid"
name="boxen-smoke-$agent-$rtk-$$"
fixture=""
started=0
cleanup() {
  local result=$?
  trap - EXIT
  if [[ "$started" == 1 ]]; then
    if "$sbx_bin" stop "$name"; then
      if [[ "$result" == 0 ]]; then
        "$sbx_bin" rm --force "$name" || result=1
      else
        printf 'Failed test environment retained, stopped: %s\n' "$name" >&2
      fi
    else
      printf 'SBX may already have removed the failed environment: %s\n' "$name" >&2
      result=1
    fi
  fi
  if [[ -n "$fixture" ]]; then
    python3 - "$fixture" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1])
PY
  fi
  rm -rf "$lock"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$sbx_bin" ls --json > "$logs/$agent-$rtk-before.json"
# sbx builds the local kits into sbx-kit-src images; the first build needs room.
cached=0
if "$docker_bin" image ls --format '{{.Repository}}' | grep -q sbx-kit-src; then cached=1; fi
python3 - "$logs/$agent-$rtk-before.json" "$project" "$cached" <<'PY'
import json, pathlib, shutil, sys
sandboxes = json.load(open(sys.argv[1]))["sandboxes"]
active = [s["name"] for s in sandboxes if s["status"] != "stopped"]
if active:
    raise SystemExit("Stop other sandboxes before this test: " + ", ".join(active))
meminfo = pathlib.Path("/proc/meminfo")
if meminfo.exists():
    available = next(int(line.split()[1]) for line in meminfo.read_text().splitlines()
                     if line.startswith("MemAvailable:"))
    if available < 4 * 1024 * 1024:
        raise SystemExit("Need 4 GiB available: 2 GiB guest plus 2 GiB host headroom")
cached = sys.argv[3] == "1"
required_gib = 3 if cached else 12
if shutil.disk_usage(sys.argv[2]).free < required_gib * 1024**3:
    raise SystemExit(f"Need at least {required_gib} GiB free disk (kit image cached: {cached})")
PY
fixture="$(mktemp -d "$logs/workspace.XXXXXX")"
python3 - "$fixture" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
(p / "bytes").write_bytes(bytes(range(256)))
(p / ".hidden").write_text("preserved\n")
PY
started=1
"$project/boxen" create "$name" "$fixture" --agent "$agent" \
  --plugins "$plugins" --cpus 2 --memory 2g --no-tui 2>&1 | tee "$logs/$agent-$rtk-create.log"
"$project/boxen" check "$name"
if [[ "$agent" != shell ]]; then "$sbx_bin" exec "$name" bash -lc "$agent --version"; fi
# Exercise the workload's entry script, which starts what BOXEN_AGENT names.
"$project/boxen" run "$name" -- --version
case "$agent:$rtk" in
  claude:rtk) "$sbx_bin" exec "$name" grep -q 'rtk hook claude' /home/agent/.claude/settings.json ;;
  codex:rtk) "$sbx_bin" exec "$name" test -f /home/agent/.codex/hooks.json ;;
  shell:rtk|grok:rtk) grep -q 'RTK hooks apply to Claude and Codex' "$logs/$agent-$rtk-create.log" ;;
  claude:nortk) "$sbx_bin" exec "$name" sh -c '! grep -q "rtk hook claude" /home/agent/.claude/settings.json' ;;
esac
printf 'PASS RTK as chosen (%s) for %s\n' "$rtk" "$agent"
"$sbx_bin" exec -i "$name" python3 - <<'PY'
from pathlib import Path
p = Path.cwd()
assert str(p) == "/home/agent/workspace", p
assert (p / "bytes").read_bytes() == bytes(range(256))
assert (p / ".hidden").read_text() == "preserved\n"
(p / ".hidden").write_text("guest edit\n")
print("PASS native workspace copy, hidden and binary files, and launch directory")
PY
[[ "$(cat "$fixture/.hidden")" == preserved ]]
"$sbx_bin" inspect "$name" --json |
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({"runtime_mounts": d.get("runtime_mounts", [])}))' \
  > "$logs/$agent-$rtk-inspect.json"
python3 - "$logs/$agent-$rtk-inspect.json" "$fixture" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert sys.argv[2] not in json.dumps(d.get("runtime_mounts", []))
print("PASS workspace copy has no source mount and guest edits leave host unchanged")
PY
"$sbx_bin" exec "$name" sh -c 'test "$(readlink /workspace)" = /home/agent/workspace'
# No standing sudo; --with-sudo grants it to one session.
if "$sbx_bin" exec "$name" sudo -n true 2>/dev/null; then
  echo 'FAIL agent has standing sudo' >&2
  exit 1
fi
"$project/boxen" shell --with-sudo "$name" sudo -n true
printf 'PASS no standing sudo; --with-sudo session works\n'
# The copied workspace, including work done after the copy, survives a stop
# and resume: no Boxen kit declares a volume, so this is the filesystem's.
"$sbx_bin" exec "$name" sh -c 'cd /home/agent/workspace && echo uncommitted > after-copy &&
  head -c 1048576 /dev/urandom > random && sha256sum after-copy random bytes' > "$logs/$agent-$rtk-digests.txt"
"$sbx_bin" stop "$name"
"$sbx_bin" run --detached --name "$name" >/dev/null
for ((attempt = 0; attempt < 60; attempt++)); do
  if "$sbx_bin" exec "$name" true 2>/dev/null; then break; fi
  sleep 1
done
"$sbx_bin" exec "$name" sh -c 'cd /home/agent/workspace && sha256sum after-copy random bytes' |
  diff "$logs/$agent-$rtk-digests.txt" -
"$sbx_bin" exec "$name" sh -c 'test "$(cat /home/agent/workspace/.hidden)" = "guest edit"'
printf 'PASS copied workspace and later work survive a stop and resume\n'
printf 'PASS %s (%s) v3 sandbox and copied workspace\n' "$agent" "$rtk"
