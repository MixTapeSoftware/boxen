"""Run the real control script with fake CLI tools; no daemon, VM, or network."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CONTROL = ROOT / "kits/tailscale/files/home/.local/share/boxen/tailscale-control.sh"


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
if args[0] == "status":
    print('{"BackendState":"Running"}')
    sys.exit(0 if os.environ["FAKE_READY"] == "1" else 1)
if args[0] == "up":
    sys.exit(int(os.environ["FAKE_UP_EXIT"]))
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
        result = self.run_control("join", "test-node", "--auth-key-stdin", stdin=key, ok=exit_code == 0)
        self.assertEqual(result.returncode, exit_code)
        call, = self.calls("up")
        self.assertEqual(call["key_digest"], hashlib.sha256(key.encode()).hexdigest())
        self.assertEqual(call["key_mode"], 0o600)
        self.assertNotIn(key.strip(), json.dumps(self.calls()) + result.stdout + result.stderr)
        self.assertEqual(list(self.directory.glob("join.*")), [])
        self.assertIn("--hostname=test-node", call["args"])
        # The agent user must not be able to reconfigure the node.
        self.assertFalse(any(a.startswith("--operator") for a in call["args"]))

    def test_auth_file_is_private_and_removed_after_success(self):
        self.assert_key_transport(0)

    def test_auth_file_is_removed_after_failure(self):
        self.assert_key_transport(17)

    def test_empty_auth_key_is_rejected_and_removed(self):
        self.run_control("join", "test-node", "--auth-key-stdin", ok=False)
        self.assertEqual(self.calls("up"), [])
        self.assertEqual(list(self.directory.glob("join.*")), [])

    def test_browser_join_applies_selected_preset_without_auth_key(self):
        self.env["BOXEN_SERVE_PRESET"] = "supabase"
        self.run_control("join", "test-node")
        self.assertEqual(self.calls("up"), [{"args": ["up", "--hostname=test-node"]}])
        self.assertEqual(len(self.calls("serve")), 7)

    def test_single_port_cannot_replace_the_preset(self):
        # The preset owns :443 -> 3000; tailscaled persists serve config, so a
        # replacement would silently break the preset.
        self.env["BOXEN_SERVE_PRESET"] = "supabase"
        result = self.run_control("serve", "5173", ok=False)
        self.assertIn("Supabase preset", result.stderr)
        self.assertEqual(self.calls(), [])
        self.run_control("serve", "supabase")

    def test_hostnames_match_sandbox_names(self):
        for value in ("dotted.name", "-leading", "x"):
            with self.subTest(value=value):
                self.run_control("join", value, ok=False)
        self.assertEqual(self.calls(), [])

    def test_daemon_timeout_prevents_join(self):
        self.env["FAKE_READY"] = "0"
        result = self.run_control("join", "test-node", ok=False)
        self.assertIn("Daemon not ready", result.stderr)
        self.assertEqual(len(self.calls("status")), 30)
        self.assertEqual(self.calls("up"), [])

    def test_route_failure_stops_remaining_routes(self):
        self.env["FAKE_SERVE_FAIL_AT"] = "2"
        result = self.run_control("serve", "supabase", ok=False)
        self.assertEqual(result.returncode, 19)
        self.assertEqual(len(self.calls("serve")), 2)


class TailscaleControlV3(TailscaleControl):
    """The v3 image's copy must behave the same as the v2 kit's."""
    control = ROOT / "v3/boxen/scripts/tailscale-control.sh"


if __name__ == "__main__":
    unittest.main()
