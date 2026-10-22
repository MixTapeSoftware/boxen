# syntax=docker/dockerfile:1
# The digest is the one the registry resolved for the shell-docker tag on
# 2026-10-22; all three Dockerfiles carry the same one.
FROM docker/sandbox-templates:shell-docker@sha256:b178ca62ec2e79af2a044e3ec321bdb72188690e1c15d573ea5524b397554d3d
USER agent
WORKDIR /home/agent/workspace
ENTRYPOINT ["bash"]
CMD ["-l"]
