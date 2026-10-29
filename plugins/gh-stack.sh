# GitHub's gh stack extension, pinned, with its agent skill.
PLUGIN_EGRESS_HOSTS="github.com codeload.github.com release-assets.githubusercontent.com objects.githubusercontent.com"
plugin_install() { box_guest user gh-stack.sh; }
