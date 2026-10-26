"""Run the host installer against a temporary HOME with fake git and tmux."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = "https://github.com/chadfennell/chadmux.git"
# Host tools the installer may use; git and tmux are faked or left out.
TOOLS = "bash sh env mkdir ln rm mv mktemp dirname basename cat chmod readlink realpath python3 grep sed tr".split()

FAKE_GIT = """#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
with open(os.environ["FAKE_GIT_LOG"], "a") as log:
    log.write(" ".join(args) + "\\n")
if args[0] == "-C" and args[2:] == ["config", "--get", "remote.origin.url"]:
    origin = pathlib.Path(args[1], ".git", "origin")
    if not origin.exists():
        sys.exit(1)
    print(origin.read_text())
elif args[0] == "clone":
    url, dest = args[-2], pathlib.Path(args[-1])
    if "tpm" in url and os.environ.get("FAKE_TPM_FAIL"):
        sys.exit(128)
    dest.mkdir(parents=True, exist_ok=True)
    (dest / ".git").mkdir()
    (dest / ".git" / "origin").write_text(url)
    if "tpm" in url:
        (dest / "bin").mkdir()
        plugins = dest / "bin" / "install_plugins"
        plugins.write_text("#!/bin/sh\\necho plugins >> " + os.environ["FAKE_GIT_LOG"] + "\\n")
        plugins.chmod(0o755)
    else:
        (dest / "tmux.conf").write_text("# chadmux\\n")
else:
    sys.exit(2)
"""


FULL = """bindings:
  github:
    apiKey:
      domains: [api.github.com, github.com, gist.github.com]
  anthropic:
    apiKey:
      domains: [api.anthropic.com, console.anthropic.com, claude.ai, mcp-proxy.anthropic.com]
    oauth:
      domains: [platform.claude.com, api.anthropic.com, console.anthropic.com, claude.ai, mcp-proxy.anthropic.com]
  openai:
    apiKey:
      domains: [api.openai.com, openai.com]
    oauth:
      domains: [auth.openai.com, chatgpt.com, api.openai.com, openai.com]
  xai:
    apiKey:
      domains: [api.x.ai]
"""

class Install(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="boxen-install-")
        self.addCleanup(temp.cleanup)
        self.directory = Path(temp.name)
        self.home = self.directory / "home"
        self.home.mkdir()
        self.tools = self.directory / "tools"
        self.tools.mkdir()
        for tool in TOOLS:
            found = shutil.which(tool)
            if found:
                (self.tools / tool).symlink_to(found)
        self.fakes = self.directory / "fakes"
        self.fakes.mkdir()
        self.fake("git", FAKE_GIT)
        self.fake("tmux", "#!/bin/sh\nexit 0\n")
        self.log = self.directory / "git.log"
        self.env = {"HOME": str(self.home), "FAKE_GIT_LOG": str(self.log),
                    "PATH": f"{self.fakes}{os.pathsep}{self.tools}"}

    def fake(self, name, body):
        path = self.fakes / name
        path.write_text(body)
        path.chmod(0o755)

    def install(self, *args, ok=True):
        result = subprocess.run([os.environ.get("TEST_BASH", "bash"), str(ROOT / "install"), *args],
                                env=self.env, input="", text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode == 0, ok, result.stderr + result.stdout)
        return result

    def test_links_the_launcher_and_skips_chadmux_unless_chosen(self):
        result = self.install()
        link = self.home / ".local/bin/bxn"
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.resolve(), (ROOT / "bxn").resolve())
        self.assertIn("./install --chadmux", result.stdout)
        self.assertFalse((self.home / ".tmux.conf").exists())
        self.install()
        self.assertTrue(link.is_symlink())

    def test_says_nothing_about_the_tailnet_policy(self):
        # Only a sandbox with the tailscale plugin needs it; create shows it then.
        result = self.install("--no-chadmux")
        self.assertNotIn("tagOwners", result.stdout + result.stderr)

    def test_writes_the_credential_bindings(self):
        # sbx approves a third-party kit's credential through a prompt on the
        # first interactive run; boxen's sandboxes start detached, so the
        # bindings are written here instead: github for gh-auth, and each
        # agent's own service, including the OAuth sign-in Claude Code makes
        # from inside the sandbox, which the proxy refuses without one.
        credentials = self.home / ".config/sbx/credentials.yaml"
        result = self.install("--no-chadmux")
        self.assertIn("Approved the kits' credentials (github, anthropic, openai, xai)", result.stdout)
        text = credentials.read_text()
        self.assertTrue(text.startswith("# Written by boxen's install."))
        self.assertEqual(text[text.index("bindings:"):], FULL)
        # sandboxd reads the file when it starts and not again.
        self.assertIn("sbx daemon restart", result.stdout)
        self.assertIn("stops running sandboxes", result.stdout)
        result = self.install("--no-chadmux")
        self.assertIn("bindings present", result.stdout)
        self.assertNotIn("sbx daemon restart", result.stdout)

    def test_brings_an_older_boxen_bindings_file_up_to_date(self):
        credentials = self.home / ".config/sbx/credentials.yaml"
        credentials.parent.mkdir(parents=True)
        credentials.write_text("# Written by boxen's install. Approves the gh-auth mixin's use of the github secret.\n"
                               "bindings:\n  github:\n    apiKey:\n      domains: [api.github.com, github.com, gist.github.com]\n")
        result = self.install("--no-chadmux")
        self.assertIn("Updated the credential bindings", result.stdout)
        self.assertIn("sbx daemon restart", result.stdout)
        text = credentials.read_text()
        self.assertEqual(text[text.index("bindings:"):], FULL)

    def test_leaves_someone_elses_credentials_file_alone(self):
        credentials = self.home / ".config/sbx/credentials.yaml"
        credentials.parent.mkdir(parents=True)
        before = "bindings:\n  anthropic:\n    apiKey:\n      domains: [api.anthropic.com]\n"
        credentials.write_text(before)
        result = self.install("--no-chadmux")
        self.assertEqual(credentials.read_text(), before)
        self.assertIn("without bindings for: github openai xai", result.stderr)
        for line in ("  github:", "domains: [api.github.com, github.com, gist.github.com]",
                     "  openai:", "domains: [auth.openai.com, chatgpt.com, api.openai.com, openai.com]",
                     "  xai:", "domains: [api.x.ai]"):
            self.assertIn(line, result.stdout)
        # The anthropic entry it already has is not printed again.
        self.assertNotIn("  anthropic:", result.stdout)

    def test_drops_the_old_boxen_link_into_this_checkout(self):
        bin_dir = self.home / ".local/bin"
        bin_dir.mkdir(parents=True)
        (bin_dir / "boxen").symlink_to(ROOT / "boxen")
        self.install("--no-chadmux")
        self.assertFalse((bin_dir / "boxen").is_symlink())
        self.assertTrue((bin_dir / "bxn").is_symlink())

    def test_keeps_a_boxen_that_is_not_this_launcher(self):
        bin_dir = self.home / ".local/bin"
        bin_dir.mkdir(parents=True)
        (bin_dir / "boxen").symlink_to(self.fakes / "git")
        self.install("--no-chadmux")
        self.assertEqual((bin_dir / "boxen").resolve(), (self.fakes / "git").resolve())

    def test_keeps_a_file_in_the_way(self):
        target = self.home / ".local/bin/bxn"
        target.parent.mkdir(parents=True)
        target.write_text("mine")
        self.install("--no-chadmux")
        self.assertEqual(target.read_text(), "mine")

    def test_installs_chadmux_and_tpm(self):
        self.install("--chadmux")
        conf = self.home / ".tmux.conf"
        self.assertTrue(conf.is_symlink())
        self.assertEqual(conf.resolve(), (self.home / ".config/tmux/tmux.conf").resolve())
        self.assertEqual((self.home / ".config/tmux/.git/origin").read_text(), UPSTREAM)
        self.assertTrue((self.home / ".tmux/plugins/tpm/bin/install_plugins").exists())
        self.assertIn("plugins", self.log.read_text())
        self.assertEqual(list((self.home / ".config").glob(".chadmux.*")), [])
        self.assertIn("already installed", self.install("--chadmux").stdout)

    def test_never_touches_an_existing_tmux_config(self):
        (self.home / ".tmux.conf").write_text("set -g mouse on\n")
        result = self.install("--chadmux")
        self.assertIn("Keeping your tmux config", result.stdout)
        self.assertEqual((self.home / ".tmux.conf").read_text(), "set -g mouse on\n")
        self.assertFalse((self.home / ".config/tmux").exists())

    def test_needs_tmux_on_the_host(self):
        (self.fakes / "tmux").unlink()
        result = self.install("--chadmux")
        self.assertIn("needs tmux", result.stderr)
        self.assertFalse((self.home / ".tmux.conf").exists())

    def test_finishes_tpm_after_a_failed_clone(self):
        self.env["FAKE_TPM_FAIL"] = "1"
        result = self.install("--chadmux")
        self.assertIn("TPM clone failed", result.stderr)
        self.assertTrue((self.home / ".tmux.conf").is_symlink())
        del self.env["FAKE_TPM_FAIL"]
        self.install("--chadmux")
        self.assertTrue((self.home / ".tmux/plugins/tpm/bin/install_plugins").exists())

    def test_rejects_unknown_options(self):
        self.install("--chadmux-please", ok=False)


if __name__ == "__main__":
    unittest.main()
