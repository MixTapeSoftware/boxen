# Codex. Sprites ship it; the install is for an image that lacks it.
PLUGIN_EGRESS_HOSTS="api.openai.com auth.openai.com chatgpt.com openai.com registry.npmjs.org"
plugin_is_installed() { box_user sh -c '. /etc/boxen/env.sh; command -v codex' >/dev/null 2>&1; }
plugin_install() { box_guest user codex.sh; }
