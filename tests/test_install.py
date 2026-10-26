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
        link = self.home / ".local/bin/boxen"
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.resolve(), (ROOT / "boxen").resolve())
        self.assertIn("./install --chadmux", result.stdout)
        self.assertFalse((self.home / ".tmux.conf").exists())
        self.install()
        self.assertTrue(link.is_symlink())

    def test_prints_the_tailnet_policy_to_add(self):
        # The snippet joins the user's existing policy; it is not the whole file.
        result = self.install("--no-chadmux")
        self.assertIn("Add this to your tailnet policy", result.stdout)
        self.assertIn("not a replacement", result.stdout)
        # The acls form: every policy file has that section, grants is newer.
        for line in ('"tagOwners": {"tag:boxen": ["autogroup:admin"]}',
                     '"acls": [', '"action": "accept", "proto": "tcp"',
                     '"src": ["autogroup:member"]',
                     '"dst": ["tag:boxen:443,4410,4431,5432,5433,5434,8443"]',
                     "funnel"):
            self.assertIn(line, result.stdout)
        self.assertNotIn("grants", result.stdout)
        # One way among several: an admin rule that already reaches everything
        # covers sandboxes too, and the docs are where to learn the rest.
        self.assertIn("more than one way", result.stdout)
        self.assertIn('"src": ["group:admin"], "dst": ["*:*"]', result.stdout)
        self.assertIn("https://tailscale.com/kb/1018/acls", result.stdout)

    def test_writes_the_github_credential_binding(self):
        # sbx approves a third-party kit's credential through a prompt on the
        # first interactive run; boxen's sandboxes start detached, so the
        # binding is written here instead.
        credentials = self.home / ".config/sbx/credentials.yaml"
        result = self.install("--no-chadmux")
        self.assertIn("Approved the gh-auth", result.stdout)
        self.assertEqual(credentials.read_text().splitlines()[-4:], [
            "bindings:", "  github:", "    apiKey:", "      domains: [api.github.com, github.com, gist.github.com]"])
        result = self.install("--no-chadmux")
        self.assertIn("binding present", result.stdout)

    def test_leaves_someone_elses_credentials_file_alone(self):
        credentials = self.home / ".config/sbx/credentials.yaml"
        credentials.parent.mkdir(parents=True)
        before = "bindings:\n  anthropic:\n    apiKey:\n      domains: [api.anthropic.com]\n"
        credentials.write_text(before)
        result = self.install("--no-chadmux")
        self.assertEqual(credentials.read_text(), before)
        self.assertIn("without a github binding", result.stderr)
        self.assertIn("domains: [api.github.com, github.com, gist.github.com]", result.stdout)

    def test_keeps_a_file_in_the_way(self):
        target = self.home / ".local/bin/boxen"
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
