#!/usr/bin/env bash
# Docker's agent mixins the launcher and the gates put on Boxen's workload,
# by tag, and the index digest each tag had when read from the registry on
# 2026-10-22.
# These are the versions sbx v0.47.0 can read: newer Claude mixins use an
# agent-context field it rejects. Move a tag and its digest together.
mixin_ref() {
  case "$1" in
    claude) echo docker.io/docker/sbx-kit-claude-mixin:2.1.267 ;;
    codex) echo docker.io/docker/sbx-kit-codex-mixin:0.155.1 ;;
    grok) echo docker.io/docker/sbx-kit-grok-mixin:1.0.34 ;;
    *) return 1 ;;
  esac
}
mixin_digest() {
  case "$1" in
    claude) echo sha256:b1e6a727e59b2e3ed62a38900473b43a02a68ec2b716b610ffa425e232a67c76 ;;
    codex) echo sha256:225d57dbd8e2d17088ffc27381ec88e1eda3471532548f54e3f5ee3dedfdd8a9 ;;
    grok) echo sha256:4df9bfee6367fe941539dc2f23f93c1d270b15874d0d15b31c4d700805976070 ;;
    *) return 1 ;;
  esac
}
