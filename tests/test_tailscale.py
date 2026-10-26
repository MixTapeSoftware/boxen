"""Run the real control script with fake CLI tools; no daemon, VM, or network."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CONTROL = ROOT / "v3/boxen/scripts/tailscale-control.sh"


class TailscaleControl(unittest.TestCase):
    control = CONTROL

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="boxen-tailscale-test-")
        self.addCleanup(temp.cleanup)
        self.directory = Path(temp.name)
        self.log = self.directory / "calls.jsonl"
        self.env = dict(os.environ)
        self.env.pop("BOXEN_SERVE_PRESET", None)
        self.env.update(
            PATH=str(self.directory) + os.pathsep + os.environ["PATH"],
            FAKE_TAILSCALE_LOG=str(self.log),
            FAKE_TAILSCALE_RUNTIME=str(self.directory),
            FAKE_READY="1", FAKE_UP_EXIT="0", FAKE_SERVE_FAIL_AT="0",
            # What the control plane says about this node after `up`.
            FAKE_SELF_TAGS="tag:boxen", FAKE_SELF_FUNNEL_CAP="",
            # How reading the node back fails: an exit status, or junk output.
            FAKE_SELF_STATUS_EXIT="0", FAKE_SELF_JUNK="",
            # Never read a real guest's preset or node name when the tests run inside a sandbox.
            BOXEN_SERVE_PRESET_FILE=str(self.directory / "serve-preset"),
            BOXEN_TS_HOSTNAME_FILE=str(self.directory / "ts-hostname"),
        )
        self.tool("tailscale", '''
import hashlib, json, os, pathlib, stat, sys
args = sys.argv[1:]
log = pathlib.Path(os.environ["FAKE_TAILSCALE_LOG"])
prior = [json.loads(s) for s in log.read_text().splitlines()] if log.exists() else []
entry = {"args": args}
for arg in args:
    if arg.startswith("--auth-key=file:"):
        key = pathlib.Path(arg.removeprefix("--auth-key=file:"))
        entry["key_digest"] = hashlib.sha256(key.read_bytes()).hexdigest()
        entry["key_mode"] = stat.S_IMODE(key.stat().st_mode)
with log.open("a") as output:
    output.write(json.dumps(entry) + "\\n")
if args[0] == "status" and "--self" in args:
    if os.environ["FAKE_SELF_STATUS_EXIT"] != "0":
        sys.exit(int(os.environ["FAKE_SELF_STATUS_EXIT"]))
    if os.environ["FAKE_SELF_JUNK"]:
        print(os.environ["FAKE_SELF_JUNK"])
        sys.exit(0)
    me = {"HostName": "test-node", "DNSName": "test-node.tail.ts.net."}
    if os.environ["FAKE_SELF_TAGS"]:
        me["Tags"] = os.environ["FAKE_SELF_TAGS"].split(",")
    if os.environ["FAKE_SELF_FUNNEL_CAP"]:
        me["CapMap"] = {os.environ["FAKE_SELF_FUNNEL_CAP"]: None}
    print(json.dumps({"BackendState": "Running", "Self": me}))
    sys.exit(0)
if args[0] == "status":
    print('{"BackendState":"Running"}')
    sys.exit(0 if os.environ["FAKE_READY"] == "1" else 1)
if args[0] == "up":
    sys.exit(int(os.environ["FAKE_UP_EXIT"]))
if args[0] == "logout":
    sys.exit(0)
if args[0] == "serve":
    count = 1 + sum(c["args"][0] == "serve" for c in prior)
    sys.exit(19 if count == int(os.environ["FAKE_SERVE_FAIL_AT"]) else 0)
raise SystemExit("Unexpected fake tailscale command")
''')
        # Keep the production script unchanged, redirecting only its temp-file
        # dependency into the test directory instead of /var/run/tailscale.
        self.tool("mktemp", '''
import os, sys, tempfile
assert sys.argv[1:] == ["/var/run/tailscale/join.XXXXXX"]
fd, path = tempfile.mkstemp(prefix="join.", dir=os.environ["FAKE_TAILSCALE_RUNTIME"])
os.close(fd)
print(path)
''')
        self.tool("sleep", "pass\n")

    def tool(self, name, body):
        path = self.directory / name
        path.write_text("#!/usr/bin/env python3\n" + body)
        path.chmod(0o755)

    def run_control(self, *args, stdin="", ok=True):
        result = subprocess.run(
            [os.environ.get("TEST_BASH", "bash"), str(self.control), *args],
            env=self.env, input=stdin, text=True, capture_output=True, timeout=10,
        )
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def calls(self, action=None):
        calls = [json.loads(s) for s in self.log.read_text().splitlines()] if self.log.exists() else []
        return calls if action is None else [c for c in calls if c["args"][0] == action]

    def hostname(self, call):
        return next(a for a in call["args"] if a.startswith("--hostname=")).removeprefix("--hostname=")

    def test_supabase_routes(self):
        self.run_control("serve", "supabase")
        expected = [(443, 3000), (4410, 3010), (4431, 3001), (5432, 54321),
                    (5433, 54323), (5434, 54324), (8443, 8000)]
        self.assertEqual([c["args"] for c in self.calls("serve")], [
            ["serve", "--bg", f"--https={https}", f"http://127.0.0.1:{port}"]
            for https, port in expected
        ])

    def test_single_port_bounds_and_leading_zeroes(self):
        for value, port in [("1", 1), ("65535", 65535), ("00080", 80)]:
            with self.subTest(value=value):
                self.run_control("serve", value)
                self.assertEqual(self.calls("serve")[-1]["args"],
                                 ["serve", "--bg", "--https=443", f"http://127.0.0.1:{port}"])

    def test_invalid_ports_do_not_call_tailscale(self):
        for value in ("", "0", "65536", "-1", "1.5", "443; echo injected", "999999999999"):
            with self.subTest(value=value):
                self.run_control("serve", value, ok=False)
        self.assertEqual(self.calls(), [])

    def assert_key_transport(self, exit_code):
        key = "test-secret-'quotes'-$(not-a-command)\n"
        self.env["FAKE_UP_EXIT"] = str(exit_code)
        result = self.run_control("join", "--auth-key-stdin", stdin=key, ok=exit_code == 0)
        self.assertEqual(result.returncode, exit_code)
        call, = self.calls("up")
        self.assertEqual(call["key_digest"], hashlib.sha256(key.encode()).hexdigest())
        self.assertEqual(call["key_mode"], 0o600)
        self.assertNotIn(key.strip(), json.dumps(self.calls()) + result.stdout + result.stderr)
        self.assertEqual(list(self.directory.glob("join.*")), [])
        self.assertRegex(self.hostname(call), r"^boxen-[0-9a-f]{8}$")
        # Tagged, so the node never carries a user's identity or Funnel grant.
        self.assertIn("--advertise-tags=tag:boxen", call["args"])
        # The agent user must not be able to reconfigure the node.
        self.assertFalse(any(a.startswith("--operator") for a in call["args"]))

    def test_auth_file_is_private_and_removed_after_success(self):
        self.assert_key_transport(0)

    def test_auth_file_is_removed_after_failure(self):
        self.assert_key_transport(17)

    def test_empty_auth_key_is_rejected_and_removed(self):
        self.run_control("join", "--auth-key-stdin", ok=False)
        self.assertEqual(self.calls("up"), [])
        self.assertEqual(list(self.directory.glob("join.*")), [])

    def test_browser_join_applies_selected_preset_without_auth_key(self):
        self.env["BOXEN_SERVE_PRESET"] = "supabase"
        self.run_control("join")
        call, = self.calls("up")
        self.assertEqual(call["args"], ["up", f"--hostname={self.hostname(call)}", "--advertise-tags=tag:boxen"])
        self.assertEqual(len(self.calls("serve")), 7)

    def test_node_names_are_random_and_stable(self):
        # The node's name is public once tailscale serve fetches its HTTPS
        # certificate (Certificate Transparency), so it never carries the
        # sandbox's name; the guest keeps it so a rejoin reuses it.
        self.run_control("join")
        first = self.hostname(self.calls("up")[0])
        self.assertRegex(first, r"^boxen-[0-9a-f]{8}$")
        self.assertEqual((self.directory / "ts-hostname").read_text().strip(), first)
        self.run_control("join")
        self.assertEqual(self.hostname(self.calls("up")[1]), first)
        self.setUp()
        self.run_control("join")
        self.assertNotEqual(self.hostname(self.calls("up")[0]), first)

    def test_a_corrupt_name_file_is_replaced(self):
        (self.directory / "ts-hostname").write_text("my project; rm -rf /\n")
        self.run_control("join")
        self.assertRegex(self.hostname(self.calls("up")[0]), r"^boxen-[0-9a-f]{8}$")

    def test_join_prints_the_tailnet_name(self):
        result = self.run_control("join")
        self.assertIn("test-node.tail.ts.net", result.stdout)
        self.assertNotIn("test-node.tail.ts.net.", result.stdout)

    def test_join_takes_no_hostname(self):
        # A sandbox name on the command line would be the leak this guards against.
        for args in (("join", "my-project"), ("join", "my-project", "--auth-key-stdin")):
            with self.subTest(args=args):
                self.run_control(*args, stdin="tskey-fake\n", ok=False)
        self.assertEqual(self.calls(), [])

    def assert_join_refused(self, message, key=False):
        self.env["BOXEN_SERVE_PRESET"] = "supabase"
        if key:
            result = self.run_control("join", "--auth-key-stdin", stdin="tskey-fake\n", ok=False)
        else:
            result = self.run_control("join", ok=False)
        self.assertIn(message, result.stderr)
        # The node leaves the tailnet rather than staying joined in a state
        # the policy did not intend; nothing is served first.
        self.assertEqual(len(self.calls("logout")), 1)
        self.assertEqual(self.calls("serve"), [])
        self.assertLess(self.calls().index(self.calls("up")[0]), self.calls().index(self.calls("logout")[0]))

    def test_untagged_node_is_logged_out_and_refused(self):
        # A browser login by a user who does not own tag:boxen, or a key
        # without the tag, would give the agent that user's whole tailnet.
        self.env["FAKE_SELF_TAGS"] = ""
        self.assert_join_refused("tag:boxen")

    def test_untagged_node_from_a_key_join_is_refused_too(self):
        self.env["FAKE_SELF_TAGS"] = ""
        self.assert_join_refused("tag:boxen", key=True)

    def test_node_with_a_different_tag_is_refused(self):
        self.env["FAKE_SELF_TAGS"] = "tag:server"
        self.assert_join_refused("tag:boxen")

    def test_node_with_an_extra_tag_is_refused(self):
        # Permissions come from every tag, so tag:boxen plus another is not
        # the identity the policy snippet describes.
        self.env["FAKE_SELF_TAGS"] = "tag:boxen,tag:server"
        self.assert_join_refused("tag:boxen")

    def test_unverifiable_node_is_logged_out(self):
        # If the node cannot be read back after up, it stays joined with
        # whatever it was granted unless the script leaves.
        for name, env in (("status exits", {"FAKE_SELF_STATUS_EXIT": "23"}),
                          ("status prints junk", {"FAKE_SELF_JUNK": "not json"})):
            with self.subTest(name):
                self.setUp()
                self.env.update(env)
                self.assert_join_refused("Could not verify")

    def test_node_granted_funnel_is_logged_out_and_refused(self):
        # Funnel is granted by a nodeAttrs entry in the policy; the control
        # plane announces it as a node capability, in either spelling.
        for cap in ("funnel", "https://tailscale.com/cap/funnel-ports?ports=443,8443,10000"):
            with self.subTest(cap=cap):
                self.setUp()
                self.env["FAKE_SELF_FUNNEL_CAP"] = cap
                self.assert_join_refused("Funnel")

    def test_single_port_cannot_replace_the_preset(self):
        # The preset owns :443 -> 3000; tailscaled persists serve config, so a
        # replacement would silently break the preset.
        self.env["BOXEN_SERVE_PRESET"] = "supabase"
        result = self.run_control("serve", "5173", ok=False)
        self.assertIn("Supabase preset", result.stderr)
        self.assertEqual(self.calls(), [])
        self.run_control("serve", "supabase")

    def test_daemon_timeout_prevents_join(self):
        self.env["FAKE_READY"] = "0"
        result = self.run_control("join", ok=False)
        self.assertIn("Daemon not ready", result.stderr)
        self.assertEqual(len(self.calls("status")), 30)
        self.assertEqual(self.calls("up"), [])

    def test_route_failure_stops_remaining_routes(self):
        self.env["FAKE_SERVE_FAIL_AT"] = "2"
        result = self.run_control("serve", "supabase", ok=False)
        self.assertEqual(result.returncode, 19)
        self.assertEqual(len(self.calls("serve")), 2)

    def test_preset_is_read_from_the_guest_file_when_the_environment_is_reset(self):
        # The root helper may run without BOXEN_SERVE_PRESET in its
        # environment; the tailscale mixin records it at create.
        (self.directory / "serve-preset").write_text("supabase\n")
        result = self.run_control("serve", "8000", ok=False)
        self.assertIn("Supabase preset", result.stderr)
        self.assertEqual(self.calls(), [])
        self.run_control("join")
        self.assertEqual(len(self.calls("serve")), 7)


if __name__ == "__main__":
    unittest.main()
