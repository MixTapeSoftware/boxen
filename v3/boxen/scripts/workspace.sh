#!/usr/bin/env bash
set -euo pipefail
# The volume's root starts out owned by root.
chown 1000:1000 /home/agent/workspace
# The short path most tools and habits expect.
if [[ ! -e /workspace || -L /workspace ]]; then ln -sfn /home/agent/workspace /workspace; fi
