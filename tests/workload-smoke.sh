#!/usr/bin/env bash
# One disposable, memory-capped native workload; no model calls or personal keys.
set -euo pipefail
[[ $# == 1 ]] || { echo "Usage: $0 claude|codex|grok" >&2; exit 2; }
agent="$1"
case "$agent" in claude|codex|grok) ;; *) echo 'Unknown agent' >&2; exit 2 ;; esac
project="$(cd "$(dirname "$0")/.." && pwd)"
sbx_bin="${SBX_BIN:-sbx}"
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
name="agbx-smoke-$agent-$$"
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
"$sbx_bin" ls --json > "$logs/$agent-before.json"
"$sbx_bin" template ls --json > "$logs/$agent-images.json"
python3 - "$logs/$agent-before.json" "$project" "$logs/$agent-images.json" "$agent" <<'PY'
import json, pathlib, shutil, sys
sandboxes = json.load(open(sys.argv[1]))["sandboxes"]
active = [s["name"] for s in sandboxes if s["status"] != "stopped"]
if active:
    raise SystemExit("Stop other sandboxes before this test: " + ", ".join(active))
meminfo = pathlib.Path("/proc/meminfo")
if meminfo.exists():
    available = next(int(line.split()[1]) for line in meminfo.read_text().splitlines()
                     if line.startswith("MemAvailable:"))
    if available < 3 * 1024 * 1024:
        raise SystemExit("Need 3 GiB available: 1 GiB guest plus 2 GiB host headroom")
tag = {"grok": "shell-docker", "claude": "claude-code-docker", "codex": "codex-docker"}[sys.argv[4]]
images = json.load(open(sys.argv[3]))["images"]
cached = any(i["repository"] == "docker.io/docker/sandbox-templates" and i["tag"] == tag for i in images)
required_gib = 3 if cached else 6
if shutil.disk_usage(sys.argv[2]).free < required_gib * 1024**3:
    raise SystemExit(f"Need at least {required_gib} GiB free disk (base image cached: {cached})")
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
"$project/agbx" create "$name" "$fixture" --agent "$agent" \
  --plugins rtkplus,matt-pocock-skills,gh-auth --cpus 2 --memory 1g
"$project/agbx" check "$name"
"$sbx_bin" exec "$name" "$agent" --version
# Exercise the selected workload's entrypoint, including Claude's extra settings.
"$project/agbx" run "$name" -- --version
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
  > "$logs/$agent-inspect.json"
python3 - "$logs/$agent-inspect.json" "$fixture" <<'PY'
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
"$project/agbx" shell --with-sudo "$name" sudo -n true
printf 'PASS no standing sudo; --with-sudo session works\n'
# sbx kit add recreates the container. The copied workspace, including work
# done after the copy, must survive on its kit volume.
"$sbx_bin" exec "$name" sh -c 'echo uncommitted > /home/agent/workspace/after-copy'
"$sbx_bin" kit add "$name" "$project/kits/just"
"$sbx_bin" exec "$name" sh -c 'test "$(cat /home/agent/workspace/after-copy)" = uncommitted && test -f /home/agent/workspace/bytes'
printf 'PASS copied workspace survives sbx kit add\n'
printf 'PASS %s workload and copied workspace\n' "$agent"
