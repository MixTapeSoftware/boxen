# Overmind, built with Go; tmux comes with the base packages.
PLUGIN_EGRESS_HOSTS="proxy.golang.org sum.golang.org storage.googleapis.com"
plugin_install() { box_guest user overmind.sh; }
