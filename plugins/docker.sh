# Docker Engine and Compose, with dockerd as a sprite-env service. Docker in
# a Sprite needs the privileged profile; tests/sprite/spike.sh (item 4)
# checks that it works at all.
PLUGIN_PRIVILEGES=privileged
PLUGIN_EGRESS_HOSTS="registry-1.docker.io auth.docker.io production.cloudflare.docker.com docker.io ghcr.io pkg-containers.githubusercontent.com public.ecr.aws d5l0dvt14r5h8.cloudfront.net d2glxqk2uabbnd.cloudfront.net"
plugin_install() { box_guest root docker-root.sh "$BOX_USER"; }
