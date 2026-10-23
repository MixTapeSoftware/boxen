#!/usr/bin/env bash
set -euo pipefail
source /etc/boxen/env.sh
# The binary only; the RTK mixins register its hooks with the chosen agent.
curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/v0.51.0/install.sh | RTK_VERSION=v0.51.0 sh
rtk --version
