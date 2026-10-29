# RTK, and its hook for Claude Code or Codex; bxn leaves it out for other agents.
PLUGIN_EGRESS_HOSTS="raw.githubusercontent.com github.com release-assets.githubusercontent.com objects.githubusercontent.com"
plugin_install() {
  box_guest user rtk-install.sh &&
    case "${BOX_AGENT:-shell}" in
      claude) box_guest user rtk-claude-hook.sh ;;
      codex) box_guest user rtk-codex-hook.sh ;;
      *) true ;;
    esac
}
