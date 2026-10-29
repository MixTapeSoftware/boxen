# A fine-grained GitHub token for gh and Git, stored in the Sprite as GH_TOKEN.
# bxn asks for the token; this points Git at gh's credential helper.
PLUGIN_EGRESS_HOSTS="github.com api.github.com gist.github.com"
plugin_install() { box_guest user gh-auth.sh; }
