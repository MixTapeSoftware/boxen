# Claude Code. Sprites ship it; the install is for an image that lacks it.
# Each teammate signs in with /login and their own subscription.
PLUGIN_EGRESS_HOSTS="claude.ai api.anthropic.com console.anthropic.com platform.claude.com statsig.anthropic.com mcp-proxy.anthropic.com downloads.claude.ai storage.googleapis.com"
plugin_is_installed() { box_user sh -c '. /etc/boxen/env.sh; command -v claude' >/dev/null 2>&1; }
plugin_install() { box_guest user claude.sh; }
