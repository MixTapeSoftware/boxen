#!/usr/bin/env bash
# Task 7 gate: the workload smoke test on every agent, with and without RTK,
# then a Tailscale box through the restart smoke test, as one aggregate
# result. Each smoke run makes its sandbox through ./bxn, inside this gate's
# own registry, and removes it itself; the library removes v3-ts. Needs sbx,
# Docker with buildx, jq and python3; one sandbox runs at a time. Run from anywhere:
#   bash tests/host/smoke-gate.sh
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/../.." || exit 2
gate_begin smoke-gate

for agent in shell claude codex grok; do
  for rtk in rtk nortk; do
    check "smoke $agent $rtk" bash tests/workload-smoke.sh "$agent" "$rtk"
  done
done

say "=== Tailscale: restart, Docker daemon and state"
create_sandbox v3-ts -- ./bxn create v3-ts --no-copy --tailscale --no-tui
check 'smoke tailscale' bash tests/sbx-smoke.sh v3-ts
gate_end
