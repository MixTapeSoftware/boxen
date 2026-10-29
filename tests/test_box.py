"""The plugin contract and Sprite policies in lib/box.sh, against a fake sprite."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FAKE = ROOT / "tests/fakes/sprite"
PRELUDE = f"""
set -euo pipefail
PROJECT_DIR={ROOT}
die() {{ printf 'die: %s\\n' "$*" >&2; exit 1; }}
warn() {{ printf 'warn: %s\\n' "$*" >&2; }}
log() {{ printf '[+] %s\\n' "$*"; }}
source "$PROJECT_DIR/lib/box.sh"
need_sprite
BOX_NAME=me-web
"""


class Box(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="boxen-box-test-")
        self.addCleanup(temp.cleanup)
        self.directory = Path(temp.name)
        self.log = self.directory / "calls.jsonl"
        self.env = dict(os.environ, SPRITE_BIN=str(FAKE), FAKE_SPRITE_LOG=str(self.log),
                        FAKE_SPRITE_STATE=str(self.directory / "state"), BOXEN_POLICY_WAIT="1")
        self.env.pop("BOXEN_SPRITE_ORG", None)

    def bash(self, script, ok=True, stdin="", **env):
        result = subprocess.run([os.environ.get("TEST_BASH", "bash"), "-c", PRELUDE + script],
                                env=dict(self.env, **env), input=stdin, capture_output=True, text=True, timeout=30)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return result

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_root_and_user_run_through_sprite_exec_with_stdin(self):
        self.bash("printf 'hi' | box_root apt-get update; box_user whoami </dev/null")
        calls = self.calls()
        self.assertEqual(calls[0]["args"], ["exec", "-s", "me-web", "--no-port-forward", "--", "sudo", "-n", "apt-get", "update"])
        self.assertEqual(calls[0]["stdin"], "hi")
        self.assertEqual(calls[1]["args"], ["exec", "-s", "me-web", "--no-port-forward", "--", "whoami"])

    def test_the_organization_follows_the_subcommand(self):
        self.bash("box_user true </dev/null; sprite_cmd 'checkpoint create' -s me-web", BOXEN_SPRITE_ORG="team")
        self.assertEqual([c["args"][:3] for c in self.calls()], [["exec", "-o", "team"], ["checkpoint", "create", "-o"]])

    def test_set_env_sends_the_value_on_stdin_only(self):
        secret = "s3cr3t 'quoted' $HOME"
        self.bash('box_set_env API_TOKEN "$VALUE"', VALUE=secret)
        call = self.calls()[0]
        self.assertNotIn(secret, json.dumps(call["args"]))
        self.assertEqual(call["args"][-1], "API_TOKEN")
        # The stdin line is an export a shell reads back as the same value.
        out = subprocess.run(["bash", "-c", call["stdin"] + 'printf %s "$API_TOKEN"'], capture_output=True, text=True)
        self.assertEqual(out.stdout, secret)
        # And the guest side replaces an earlier line for the same name.
        home = self.directory / "home"; home.mkdir()
        (home / ".config/boxen").mkdir(parents=True)
        (home / ".config/boxen/env.sh").write_text("export API_TOKEN=old\nexport OTHER=1\n")
        guest = call["args"][call["args"].index("--") + 1:]
        subprocess.run(guest, input=call["stdin"], env=dict(os.environ, HOME=str(home)), check=True, text=True)
        text = (home / ".config/boxen/env.sh").read_text()
        self.assertEqual(text.count("API_TOKEN"), 1)
        self.assertIn("export OTHER=1", text)
        self.assertEqual((home / ".config/boxen/env.sh").stat().st_mode & 0o777, 0o600)

    def test_upload_sends_the_guest_folder_as_a_tar_on_stdin(self):
        result = subprocess.run(["bash", "-c", PRELUDE + "box_upload_guest"], env=self.env, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        line = json.loads(self.log.read_text().splitlines()[0])
        self.assertEqual(line["args"][:7], ["exec", "-s", "me-web", "--no-port-forward", "--", "sudo", "-n"])
        self.assertIn("/etc/boxen/env.sh", " ".join(line["args"]))
        self.assertIn("./check.sh", line["stdin"])   # tar's member names are in the clear

    def test_policy_document_is_the_baseline_plus_unique_hosts(self):
        out = self.bash("policy_document example.com github.com example.com '*.example.org'").stdout
        doc = json.loads(out)
        baseline = json.loads((ROOT / "policies/sprite-baseline.json").read_text())
        self.assertEqual(doc["rules"][:len(baseline["rules"])], baseline["rules"])
        added = doc["rules"][len(baseline["rules"]):]
        self.assertEqual(added, [{"domain": "example.com", "action": "allow"},
                                 {"domain": "*.example.org", "action": "allow"}])

    def test_merge_reads_the_current_policy_and_keeps_it(self):
        current = '{"rules":[{"include":"defaults"},{"domain":"bad.com","action":"deny"}]}'
        out = self.bash("printf '%s' \"$CURRENT\" | policy_merge new.com bad.com", CURRENT=current).stdout
        rules = json.loads(out)["rules"]
        self.assertEqual(rules[:2], json.loads(current)["rules"])
        self.assertEqual(rules[2:], [{"domain": "new.com", "action": "allow"}, {"domain": "bad.com", "action": "allow"}])

    def test_hosts_are_validated(self):
        for host in ("github.com", "*.github.com", "a-b.c.io"):
            self.bash(f"valid_host '{host}'")
        for host in ("*", "github", "-a.com", "a..com", "http://a.com", "a.com/x", "*.*.com", "A.COM"):
            self.assertNotEqual(self.bash(f"valid_host '{host}'", ok=False).returncode, 0, host)

    def test_lock_down_sets_both_policies_and_reads_them_back(self):
        self.bash('lock_down me-web privileged "$(policy_document example.com)"')
        calls = self.calls()
        posts = [c for c in calls if c["args"][0] == "api" and "POST" in c["args"]]
        self.assertEqual([c["args"][3] for c in posts], ["/policy/network", "/policy/privileges"])
        self.assertEqual(json.loads(posts[1]["stdin"]), {"profile": "privileged"})
        # Read back from the API, and from the Sprite's own copy.
        gets = [c["args"][3] for c in calls if c["args"][0] == "api" and "POST" not in c["args"]]
        self.assertIn("/policy/network", gets)
        reads = [c["args"][6] for c in calls if c["args"][:6] == ["exec", "-s", "me-web", "--", "sh", "-c"]
                 and "/.sprite/policy/network.json" in c["args"][6]]
        self.assertTrue(reads)
        # The fake ends a copy in a space as this does, so an empty file reads as present.
        self.assertIn('cat "$f"; printf " "', reads[0])

    def test_lock_down_fails_when_the_sprite_enforces_something_else(self):
        # The Sprite still unrestricted, or missing a rule: never continue.
        for inside in ('{"rules": []}', '{"rules": [{"include": "defaults"}]}', "not json"):
            result = self.bash('lock_down me-web standard "$(policy_document example.com)"', ok=False,
                               FAKE_INSIDE_POLICY=inside)
            self.assertNotEqual(result.returncode, 0, inside)
            result = self.bash('lock_down me-web standard "$(policy_document example.com)"', ok=False,
                               FAKE_API_POLICY=inside)
            self.assertNotEqual(result.returncode, 0, inside)

    def test_lock_down_fails_when_the_sprite_has_an_empty_copy(self):
        # An empty file is there but holds no policy; it is not a missing one.
        result = self.bash('lock_down me-web standard "$(policy_document example.com)"', ok=False,
                           FAKE_INSIDE_POLICY="")
        self.assertNotEqual(result.returncode, 0)

    def test_lock_down_fails_when_a_blocked_host_resolves_inside(self):
        # The API only shows Fly saved the policy; the lookup shows the Sprite enforces it.
        result = self.bash('lock_down me-web standard "$(policy_document example.com)"', ok=False,
                           FAKE_CANARY="resolves")
        self.assertNotEqual(result.returncode, 0)
        result = self.bash('lock_down me-web standard "$(policy_document example.com)"', ok=False,
                           FAKE_CANARY="")
        self.assertNotEqual(result.returncode, 0, "an exec that prints nothing is not a pass")

    def test_the_canary_is_a_host_the_document_does_not_allow(self):
        def canary(*hosts):
            return self.bash(f'policy_canary "$(policy_document {" ".join(hosts)})"').stdout.strip()
        self.assertEqual(canary(), "example.org")
        self.assertEqual(canary("example.org"), "example.net")
        self.assertEqual(canary("example.org", "example.net"), "iana.org")
        # A wildcard allows only the names under it (and, to be safe, its apex).
        self.assertEqual(canary("'*.example.org'"), "example.net")
        self.assertEqual(canary("'*.net'"), "example.org")
        self.assertEqual(canary("'*.org'"), "example.net")
        self.assertEqual(canary("'*.org'", "example.net"), "")
        self.assertEqual(canary("'*'"), "")
        self.assertEqual(self.bash("""policy_canary '{"rules":[]}'""").stdout, "")

    def test_lock_down_relies_on_the_api_where_the_sprite_has_no_copy(self):
        # The spike's Sprite had no /.sprite/policy/network.json.
        self.bash('lock_down me-web standard "$(policy_document example.com)"', FAKE_NO_INSIDE_POLICY="1")
        result = self.bash('lock_down me-web standard "$(policy_document example.com)"', ok=False,
                           FAKE_NO_INSIDE_POLICY="1", FAKE_API_POLICY='{"rules": []}')
        self.assertNotEqual(result.returncode, 0)

    def test_lock_down_accepts_rules_the_sprite_adds_and_pretty_printing(self):
        doc = self.bash("policy_document example.com").stdout
        rules = json.loads(doc)["rules"] + [{"domain": "extra.dev", "action": "allow"}]
        self.bash('lock_down me-web standard "$(policy_document example.com)"',
                  FAKE_INSIDE_POLICY=json.dumps({"rules": rules}, indent=2))

    def test_allow_all_is_an_empty_rule_list_and_verified_as_such(self):
        self.bash("""lock_down me-web standard '{"rules":[]}'""")
        self.assertNotEqual(self.bash("""lock_down me-web standard '{"rules":[]}'""", ok=False,
                                      FAKE_INSIDE_POLICY='{"rules":[{"include":"defaults"}]}').returncode, 0)

    def test_a_failed_post_fails_lock_down(self):
        self.assertNotEqual(self.bash('lock_down me-web standard "$(policy_document)"', ok=False,
                                      FAKE_FAIL="/policy/network").returncode, 0)


class Plugins(unittest.TestCase):
    INDEX = ROOT / "plugins/plugins.tsv"

    def rows(self):
        return [line.split("\t") for line in self.INDEX.read_text().splitlines()[1:]]

    def meta(self, plugin, field):
        script = PRELUDE + f"plugin_meta {plugin} {field}"
        out = subprocess.run(["bash", "-c", script], env=dict(os.environ, SPRITE_BIN=str(FAKE)),
                             capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        return out.stdout.strip()

    def test_the_index_names_every_plugin_file_once(self):
        ids = [r[0] for r in self.rows()]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(sorted(ids), sorted(p.stem for p in (ROOT / "plugins").glob("*.sh")))
        for row in self.rows():
            self.assertEqual(len(row), 3, row)
            self.assertIn(row[1], ("yes", "no"), row)

    def test_gh_auth_is_on_by_default_and_slow_or_privileged_ones_are_not(self):
        defaults = {r[0] for r in self.rows() if r[1] == "yes"}
        self.assertIn("gh-auth", defaults)
        self.assertFalse(defaults & {"nvchad", "chromium", "docker", "supabase-serve"})

    def test_requirements_come_earlier_in_the_index(self):
        ids = [r[0] for r in self.rows()]
        for plugin in ids:
            for need in self.meta(plugin, "PLUGIN_REQUIRES").split():
                self.assertLess(ids.index(need), ids.index(plugin), plugin)

    def test_metadata_is_well_formed(self):
        files = list((ROOT / "plugins").glob("*.sh")) + list((ROOT / "plugins/agents").glob("*.sh"))
        for path in files:
            ident = path.stem if path.parent.name == "plugins" else "agent:" + path.stem
            with self.subTest(plugin=ident):
                self.assertIn(self.meta(ident, "PLUGIN_PRIVILEGES"), ("standard", "privileged"))
                hosts = self.meta(ident, "PLUGIN_EGRESS_HOSTS").split()
                self.assertTrue(hosts)
                check = "for h in \"$@\"; do valid_host \"$h\" || { echo \"$h\"; exit 1; }; done"
                out = subprocess.run(["bash", "-c", PRELUDE + check, "bash", *hosts],
                                     env=dict(os.environ, SPRITE_BIN=str(FAKE)), capture_output=True, text=True)
                self.assertEqual(out.returncode, 0, out.stdout)
                text = path.read_text()
                self.assertIn("plugin_install()", text)
                # Plugins reach the Sprite only through the contract.
                self.assertNotRegex(text, r"\bsprite(_cmd|_exec)?\s")
                self.assertNotIn("$BOX_NAME", text)

    def test_only_docker_asks_for_the_privileged_profile(self):
        privileged = [r[0] for r in self.rows() if self.meta(r[0], "PLUGIN_PRIVILEGES") == "privileged"]
        self.assertEqual(privileged, ["docker"])

    def test_every_guest_script_a_plugin_names_exists(self):
        for path in list((ROOT / "plugins").glob("*.sh")) + list((ROOT / "plugins/agents").glob("*.sh")):
            for script in re.findall(r"box_guest (?:root|user) ([\w.-]+\.sh)", path.read_text()):
                self.assertTrue((ROOT / "guest" / script).is_file(), (path.name, script))

    def test_plugins_run_isolated_and_skip_what_is_installed(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        log = Path(temp.name) / "calls.jsonl"
        env = dict(os.environ, SPRITE_BIN=str(FAKE), FAKE_SPRITE_LOG=str(log), FAKE_SPRITE_STATE=temp.name)
        out = subprocess.run(["bash", "-c", PRELUDE + "plugin_run just </dev/null; plugin_run agent:claude </dev/null; "
                              "declare -F plugin_install && exit 9; exit 0"],
                             env=env, capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        calls = [json.loads(l)["args"] for l in log.read_text().splitlines()]
        self.assertEqual(calls[0][-2:], ["bash", "/usr/local/share/boxen/just.sh"])
        # The fake exec succeeds, so claude counts as installed and its installer never runs.
        self.assertFalse(any("claude.sh" in " ".join(c) for c in calls))


if __name__ == "__main__":
    unittest.main()
