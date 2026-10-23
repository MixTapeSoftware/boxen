# syntax=docker/dockerfile:1
# Boxen's workload: the tools are baked in here, and agents come as Docker's
# agent mixins. A mixin may not change a file this image changed, which is why
# apt runs here and not in a mixin.
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
COPY scripts/ /usr/local/share/boxen/
WORKDIR /home/agent/workspace
ENTRYPOINT ["bash", "/usr/local/share/boxen/boxen-entry.sh"]
