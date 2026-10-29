#!/usr/bin/env bash
# Git asks gh for GitHub credentials; gh reads GH_TOKEN, which bxn stores in
# ~/.config/boxen/env.sh. Configuration needs no token.
set -euo pipefail
source /etc/boxen/env.sh 2>/dev/null || true
git config --global credential.https://github.com.helper '!gh auth git-credential'
git config --global credential.https://gist.github.com.helper '!gh auth git-credential'
