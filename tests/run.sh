#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash -n agent-sbx
while IFS= read -r script; do bash -n "$script"; done < <(find lib kits agents tests -name '*.sh' -type f)
python3 -m unittest discover -s tests -p 'test_*.py' -v
