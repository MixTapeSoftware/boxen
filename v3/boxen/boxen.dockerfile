# syntax=docker/dockerfile:1
# The template Docker's pinned Claude and Codex workloads are built on. A
# mixin overlays only the files its own steps add or change, so the base must
# be the one those workloads carry, package database included.
# The digest is the one the registry resolved for the shell-docker tag on
# 2026-10-22; every v3 Dockerfile carries the same one.
FROM docker/sandbox-templates:shell-docker@sha256:b178ca62ec2e79af2a044e3ec321bdb72188690e1c15d573ea5524b397554d3d
COPY scripts/env.sh /etc/boxen/env.sh
USER root
COPY scripts/core-root.sh /usr/local/share/boxen/core-root.sh
RUN bash /usr/local/share/boxen/core-root.sh
USER agent
WORKDIR /home/agent
COPY --chown=root:root scripts/core-user.sh /usr/local/share/boxen/core-user.sh
RUN bash /usr/local/share/boxen/core-user.sh
# Runtime hooks and checks last: they change often and install nothing.
USER root
COPY scripts/ /usr/local/share/boxen/
