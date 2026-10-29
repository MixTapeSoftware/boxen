# The 1Password CLI, pinned; bxn asks for a service account token.
PLUGIN_EGRESS_HOSTS="cache.agilebits.com *.1password.com *.1password.eu *.1password.ca"
plugin_install() { box_guest user 1pass.sh; }
