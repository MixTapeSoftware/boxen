# Grok Build, through xAI's installer. It reads XAI_API_KEY: bxn env NAME XAI_API_KEY.
PLUGIN_EGRESS_HOSTS="x.ai api.x.ai"
plugin_is_installed() { box_user sh -c '. /etc/boxen/env.sh; command -v grok' >/dev/null 2>&1; }
plugin_install() { box_guest user grok.sh; }
