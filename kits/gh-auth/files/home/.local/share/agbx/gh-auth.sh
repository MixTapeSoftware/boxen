#!/usr/bin/env bash
set -euo pipefail
source /etc/sandbox-persistent.sh
# gh receives only the proxy sentinel. Configuration does not require a token.
git config --global credential.https://github.com.helper '!gh auth git-credential'
git config --global credential.https://gist.github.com.helper '!gh auth git-credential'
