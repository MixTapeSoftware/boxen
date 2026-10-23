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
COPY scripts/chromium-root.sh /usr/local/share/boxen/chromium-root.sh
RUN bash /usr/local/share/boxen/chromium-root.sh
COPY scripts/tailscale-install.sh scripts/tailscale-control.sh /usr/local/share/boxen/
RUN bash /usr/local/share/boxen/tailscale-install.sh
USER agent
WORKDIR /home/agent
COPY --chown=root:root scripts/core-user.sh /usr/local/share/boxen/core-user.sh
RUN bash /usr/local/share/boxen/core-user.sh
# One step per tool, so a change rebuilds only that tool and the ones after it.
COPY --chown=root:root scripts/fzf-bat.sh scripts/fzf-shell.sh /usr/local/share/boxen/
RUN bash /usr/local/share/boxen/fzf-bat.sh
COPY --chown=root:root scripts/just.sh /usr/local/share/boxen/just.sh
RUN bash /usr/local/share/boxen/just.sh
COPY --chown=root:root scripts/glow.sh /usr/local/share/boxen/glow.sh
RUN bash /usr/local/share/boxen/glow.sh
COPY --chown=root:root scripts/mermaid-ascii.sh /usr/local/share/boxen/mermaid-ascii.sh
RUN bash /usr/local/share/boxen/mermaid-ascii.sh
COPY --chown=root:root scripts/overmind.sh /usr/local/share/boxen/overmind.sh
RUN bash /usr/local/share/boxen/overmind.sh
COPY --chown=root:root scripts/cubic.sh /usr/local/share/boxen/cubic.sh
RUN bash /usr/local/share/boxen/cubic.sh
COPY --chown=root:root scripts/1pass.sh /usr/local/share/boxen/1pass.sh
RUN bash /usr/local/share/boxen/1pass.sh
COPY --chown=root:root scripts/rtk-install.sh /usr/local/share/boxen/rtk-install.sh
RUN bash /usr/local/share/boxen/rtk-install.sh
COPY --chown=root:root scripts/chromium.sh /usr/local/share/boxen/chromium.sh
RUN bash /usr/local/share/boxen/chromium.sh
COPY --chown=root:root scripts/nvchad.sh scripts/lazy-check.lua /usr/local/share/boxen/
RUN bash /usr/local/share/boxen/nvchad.sh
# Runtime hooks and checks last: they change often and install nothing.
COPY scripts/ /usr/local/share/boxen/
WORKDIR /home/agent/workspace
ENTRYPOINT ["bash", "/usr/local/share/boxen/boxen-entry.sh"]
