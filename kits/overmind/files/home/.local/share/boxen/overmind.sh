#!/usr/bin/env bash
set -euo pipefail
source /etc/sandbox-persistent.sh
GOBIN="$HOME/.local/bin" go install github.com/DarthSim/overmind/v2@v2.5.1
overmind --version
