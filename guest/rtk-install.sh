#!/usr/bin/env bash
set -euo pipefail
source /etc/boxen/env.sh
# The binary only; the rtkplus plugin then registers its hook with the agent.
curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/v0.51.0/install.sh | RTK_VERSION=v0.51.0 sh
rtk --version
