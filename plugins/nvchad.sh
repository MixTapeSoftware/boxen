# chadfennell/nvChad on a pinned Neovim, with tree-sitter parsers and six
# Mason language servers. The slowest plugin. Its lazygit.nvim needs lazygit.
PLUGIN_REQUIRES=lazygit
PLUGIN_EGRESS_HOSTS="github.com codeload.github.com codeberg.org api.mason-registry.dev registry.npmjs.org registry.npmmirror.com pypi.org files.pythonhosted.org hex.pm repo.hex.pm builds.hex.pm elixir-lang.org proxy.golang.org sum.golang.org"
plugin_install() { box_guest user nvchad.sh; }
