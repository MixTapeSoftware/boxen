"""Structural checks complement sbx kit validate; they do not replace it."""
from pathlib import Path
import re
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
CLI = (ROOT / "lib/cli.sh").read_text()
KITS = re.search(r'^KITS="([^"]+)"', CLI, re.M)[1].split()


def spec(name):
    return yaml.safe_load((ROOT / "kits" / name / "spec.yaml").read_text())


def allowed(name):
    return spec(name).get("permissions", {}).get("network", {}).get("allow", [])


class Kits(unittest.TestCase):
    def test_descriptors_and_assets(self):
        specs = list(ROOT.glob("kits/*/spec.yaml")) + list(ROOT.glob("agents/*/spec.yaml"))
        self.assertEqual({p.parent.name for p in ROOT.glob("kits/*/spec.yaml")}, set(KITS) | {"core", "workspace"})
        names = set()
        for path in specs:
            with self.subTest(path=path):
                data = yaml.safe_load(path.read_text())
                self.assertEqual(data["schemaVersion"], "2")
                self.assertNotIn(data["name"], names)
                names.add(data["name"])
                self.assertIn(data["kind"], ("mixin", "sandbox"))
                for hook in data.get("setup", {}).get("install", []):
                    self.assertIn(hook["user"], ("0", "1000"))
                    prefix = "bash /home/agent/"
                    self.assertTrue(hook["command"].startswith(prefix))
                    asset = path.parent / "files/home" / hook["command"][len(prefix):]
                    self.assertTrue(asset.is_file(), str(asset))
                for hook in data.get("setup", {}).get("startup", []):
                    self.assertIsInstance(hook["command"], list)
                    self.assertTrue(hook["background"])
                    asset = path.parent / "files/home" / hook["command"][-1].removeprefix("/home/agent/")
                    self.assertTrue(asset.is_file(), str(asset))

    def test_guest_paths_point_at_shipped_files(self):
        # Kits refer to each other's scripts by guest path; a rename must keep them aligned.
        shipped = {f.name for f in ROOT.glob("*/*/files/home/.local/share/agbx/*")}
        sources = list(ROOT.glob("*/*/spec.yaml")) + list(ROOT.glob("*/*/files/home/.local/share/agbx/*"))
        for source in sources + list(ROOT.glob("lib/*.sh")):
            for name in re.findall(r'\.local/share/agbx/([A-Za-z0-9_-]+\.(?:sh|py|lua))', source.read_text()):
                with self.subTest(source=source.name, name=name):
                    self.assertIn(name, shipped)

    def test_plugin_list_matches_the_launcher(self):
        plugins = re.search(r'^PLUGINS="\$KITS"', CLI, re.M)
        self.assertIsNotNone(plugins)
        listed = [line.split("\t")[0] for line in (ROOT / "plugins.tsv").read_text().splitlines()[1:]]
        self.assertEqual(listed, KITS)

    def test_identity_is_a_separate_volume_and_no_credentials_are_bundled(self):
        volume = spec("tailscale")["volumes"][0]
        self.assertEqual(volume["path"], "/var/lib/tailscale")
        self.assertEqual(volume["mode"], "0700")
        for asset in ROOT.glob("**/files/**/*"):
            if asset.is_file():
                self.assertNotEqual(asset.name, "tailscaled.state")
                self.assertNotRegex(asset.read_text(), r'tskey-auth-[A-Za-z0-9]+')
                self.assertNotIn("export OP_SERVICE_ACCOUNT_TOKEN=", asset.read_text())

    def test_every_sandbox_can_pull_public_ecr_images(self):
        # Docker is in every sandbox; public.ecr.aws serves layers from these.
        for host in ("d5l0dvt14r5h8.cloudfront.net", "d2glxqk2uabbnd.cloudfront.net"):
            self.assertIn(host, allowed("core"))

    def test_copied_workspace_lives_on_a_volume(self):
        # sbx kit add recreates the container and keeps only volumes and mounts.
        self.assertEqual(spec("workspace")["volumes"][0]["path"], "/home/agent/workspace")

    def test_nothing_reapplies_serve_routes_on_start(self):
        # tailscaled persists serve config; a startup reapply would clobber a
        # custom :443 mapping on every restart.
        self.assertNotIn("setup", spec("supabase-serve"))
        self.assertEqual(spec("supabase-serve")["environment"]["variables"]["AGBX_SERVE_PRESET"], "supabase")

    def test_optional_kits_list_only_hosts_core_lacks(self):
        core = set(allowed("core"))
        for name in KITS:
            with self.subTest(kit=name):
                self.assertFalse(core & set(allowed(name)))
        self.assertEqual(allowed("tailscale"), ["tailscale.com", "pkgs.tailscale.com", "*.tailscale.com", "*.tailscale.io"])

    def test_pinned_downloads_are_checksummed(self):
        for script in ROOT.glob("kits/*/files/home/.local/share/agbx/*.sh"):
            text = script.read_text()
            with self.subTest(script=script.name):
                self.assertNotIn("@latest", text)
                self.assertNotIn("releases/latest", text)
                downloads = len(re.findall(r'curl -fsSL "[^"]+" -o', text))
                if downloads:
                    self.assertIn("sha256sum -c", text)

    def test_proxy_preserved_and_managed_settings_untouched(self):
        core = (ROOT / "kits/core/files/home/.local/share/agbx/core-root.sh").read_text()
        self.assertNotIn("export HTTP_PROXY=", core)
        self.assertNotIn("export HTTPS_PROXY=", core)
        rtk = (ROOT / "kits/rtkplus/files/home/.local/share/agbx/rtkplus.sh").read_text()
        self.assertIn("claude-rtk.json", rtk)
        self.assertNotRegex(rtk, r'>.*\.claude/settings\.json')
        self.assertNotRegex(rtk, r'>.*\.codex/config\.toml')


if __name__ == "__main__":
    unittest.main()
