"""Structural checks on the v3 kits, plus the guest scripts run on the host
against fake tools. sbx validates the kit grammar; these pin Boxen's rules."""
from pathlib import Path
import json
import os
import re
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
V3 = ROOT / "v3"
SYNTAX = "# syntax=docker/sandbox-kit:3"
SCRIPTS = V3 / "boxen/scripts"
GUEST = "/usr/local/share/boxen/"
BASE = "docker/sandbox-templates:shell-docker"
OLD_EXECUTABLE = re.compile(r"\.local/share/boxen/[A-Za-z0-9_-]+\.(?:sh|py|lua)\b")

def kit_dirs():
    return sorted(p for p in V3.iterdir() if p.is_dir())

def descriptor(name):
    return yaml.safe_load((V3 / name / f"{name}.yaml").read_text())

def capabilities(name, type_suffix):
    return [c for c in descriptor(name)["capabilities"] if c.get("type", "").endswith("/" + type_suffix)]

def capability(name, type_suffix):
    found = capabilities(name, type_suffix)
    assert len(found) == 1, (name, type_suffix, found)
    return found[0]

def allowed(name):
    hosts = []
    for entry in capability(name, "network-policy@2")["config"]["runtime"]["allow"]:
        hosts += entry["hosts"] if isinstance(entry, dict) else [entry]
    return hosts

def hooks(name, phase):
    return [h for c in capabilities(name, "lifecycle@1") for h in c["config"].get(phase, [])]

def command_text(hook):
    return hook["command"] if isinstance(hook["command"], str) else " ".join(hook["command"])

class ScriptCase(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="boxen-v3-test-")
        self.addCleanup(temp.cleanup)
        self.directory = Path(temp.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()

    def fake(self, name, body="exit 0"):
        tool = self.bin / name
        tool.write_text(f"#!/bin/sh\n{body}\n")
        tool.chmod(0o755)
        return tool

    def run_script(self, script, *args, env=None, ok=True):
        full = dict(os.environ, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}", HOME=str(self.directory))
        full.update(env or {})
        result = subprocess.run(["bash", str(SCRIPTS / script), *args], env=full, capture_output=True, text=True, timeout=20)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return result

class Descriptors(unittest.TestCase):
    def test_every_kit_is_a_v3_descriptor_named_after_its_directory(self):
        for directory in kit_dirs():
            with self.subTest(kit=directory.name):
                path = directory / f"{directory.name}.yaml"
                self.assertTrue(path.is_file(), str(path))
                self.assertEqual(path.read_text().splitlines()[0], SYNTAX)
                data = yaml.safe_load(path.read_text())
                self.assertEqual(data["schemaVersion"], "3")
                self.assertIn(data["kind"], ("mixin", "workload"))
                self.assertTrue(data["provides"])

    def test_context_matches_the_pinned_workloads_v1_and_mixins_name_no_file(self):
        # The published docker/sbx-kit-claude:2.1.267 and sbx-kit-codex:0.155.1
        # declare agent-context@1; @1 and @2 refuse to compose.
        for directory in kit_dirs():
            name = directory.name
            with self.subTest(kit=name):
                self.assertEqual(capabilities(name, "agent-context@2"), [])
                for entry in capabilities(name, "agent-context@1"):
                    self.assertTrue(entry["config"]["content"].strip())
                    self.assertNotIn("contentFile", entry["config"])
                    if descriptor(name)["kind"] == "mixin":
                        self.assertNotIn("filename", entry["config"])
                        self.assertNotIn("directory", entry["config"])

    def test_hooks_run_as_root_or_agent_and_name_shipped_scripts(self):
        for directory in kit_dirs():
            for phase in ("install", "startup"):
                for hook in hooks(directory.name, phase):
                    with self.subTest(kit=directory.name, hook=hook.get("description")):
                        self.assertIn(hook["user"], ("0", "1000"))
                        if phase == "startup":
                            self.assertIn("background", hook)
                        for script in re.findall(re.escape(GUEST) + r"([A-Za-z0-9_.-]+)", command_text(hook)):
                            self.assertTrue((SCRIPTS / script).is_file(), script)

    def test_no_boxen_kit_declares_a_volume(self):
        for directory in kit_dirs():
            with self.subTest(kit=directory.name):
                self.assertEqual(capabilities(directory.name, "volume@1"), [])

    def test_no_executable_is_referenced_under_the_old_guest_path(self):
        for path in list(V3.rglob("*.yaml")) + list(V3.rglob("*.dockerfile")) + list(SCRIPTS.iterdir()):
            with self.subTest(path=path.name):
                self.assertFalse(OLD_EXECUTABLE.search(path.read_text()), path)

    def test_workloads_share_the_ubuntu_template_base(self):
        # The base may carry its digest (test_every_dockerfile_pins_the_same_base_digest requires it).
        for directory in kit_dirs():
            dockerfile = directory / f"{directory.name}.dockerfile"
            if dockerfile.exists():
                with self.subTest(kit=directory.name):
                    self.assertRegex(dockerfile.read_text(), r"(?m)^FROM " + re.escape(BASE) + r"(@sha256:[0-9a-f]{64})?\s*$", msg=directory.name)

class BoxenMixin(ScriptCase):
    def test_boxen_mixin_keeps_the_v2_core_hosts_on_ubuntu_mirrors(self):
        hosts = set(allowed("boxen"))
        core = yaml.safe_load((ROOT / "kits/core/spec.yaml").read_text())["permissions"]["network"]["allow"] if (ROOT / "kits/core/spec.yaml").exists() else []
        for host in core:
            self.assertIn(host, hosts)
        for host in ("archive.ubuntu.com:80", "security.ubuntu.com:443", "d5l0dvt14r5h8.cloudfront.net", "d2glxqk2uabbnd.cloudfront.net"):
            self.assertIn(host, hosts)
        self.assertFalse([h for h in hosts if "debian" in h], hosts)

    def test_dockerfile_copies_each_script_before_its_step(self):
        text = (V3 / "boxen/boxen.dockerfile").read_text()
        self.assertIn("COPY scripts/env.sh /etc/boxen/env.sh", text)
        self.assertTrue(text.rstrip().endswith("COPY scripts/ /usr/local/share/boxen/"), text[-200:])
        self.assertLess(text.index("COPY scripts/core-root.sh"), text.index("RUN bash " + GUEST + "core-root.sh"))
        self.assertLess(text.index("RUN bash " + GUEST + "core-user.sh"), text.index("COPY scripts/ /usr/local/share/boxen/"))

    def test_image_never_ships_sandbox_persistent_sh(self):
        for script in SCRIPTS.glob("*.sh"):
            with self.subTest(script=script.name):
                self.assertNotRegex(script.read_text(), r">>?\s*/etc/sandbox-persistent\.sh")
        self.assertIn("/etc/sandbox-persistent.sh", (SCRIPTS / "persist-env.sh").read_text())

    def test_build_time_scripts_source_the_image_environment(self):
        # The rc-file heredocs in core-user.sh may mention the persistence file
        # (guarded, at runtime); the scripts themselves must not source it.
        for script in SCRIPTS.glob("*.sh"):
            with self.subTest(script=script.name):
                self.assertNotRegex(script.read_text(), r"(?m)^source /etc/sandbox-persistent\.sh")

    def test_persist_env_appends_once(self):
        target = self.directory / "sandbox-persistent.sh"
        env = {"BOXEN_PERSISTENT_FILE": str(target)}
        self.run_script("persist-env.sh", env=env)
        self.run_script("persist-env.sh", env=env)
        self.assertEqual(target.read_text().count("/etc/boxen/env.sh"), 1)

    def test_env_file_is_idempotent(self):
        probe = f'. {SCRIPTS}/env.sh; . {SCRIPTS}/env.sh; printf "%s" "$PATH"'
        path = subprocess.run(["sh", "-c", probe], env={"HOME": str(self.directory), "PATH": "/usr/bin:/bin"},
                              capture_output=True, text=True).stdout
        self.assertEqual(path.count(f"{self.directory}/.local/share/mise/shims"), 1)
        self.assertEqual(path.count(f"{self.directory}/.local/bin"), 1)

    def test_proxy_variables_are_never_exported_by_the_image(self):
        for script in SCRIPTS.glob("*.sh"):
            with self.subTest(script=script.name):
                self.assertNotIn("export HTTP_PROXY=", script.read_text())
                self.assertNotIn("export HTTPS_PROXY=", script.read_text())

    def test_sudo_policy_is_an_install_hook_that_skips_cloud_boxes(self):
        # Local boxes lose standing sudo at create; cloud boxes keep Docker's default.
        self.assertNotIn("sudo-policy.sh", (V3 / "boxen/boxen.dockerfile").read_text())
        hook = next(h for h in hooks("boxen", "install") if "sudo-policy.sh" in command_text(h))
        self.assertEqual(hook["user"], "0")
        self.assertIn("BOXEN_CLOUD", hook["env"])
        text = (SCRIPTS / "sudo-policy.sh").read_text()
        self.assertIn("boxen-sudo-session", text)
        self.fake("groupadd", 'echo "groupadd $*" >> "$HOME/calls"')
        result = self.run_script("sudo-policy.sh", env={"BOXEN_CLOUD": "1"})
        self.assertIn("keeping Docker's sudo", result.stdout + result.stderr)
        self.assertFalse((self.directory / "calls").exists())

    def test_check_script_uses_the_new_helper_paths(self):
        text = (SCRIPTS / "check.sh").read_text()
        self.assertIn(GUEST + "browser-check.py", text)
        self.assertIn(GUEST + "lazy-check.lua", text)

class ShellWorkload(unittest.TestCase):
    def test_shell_is_a_plain_workload_on_the_template(self):
        data = descriptor("shell")
        self.assertEqual((data["kind"], data["provides"]), ("workload", ["shell@1.0.0"]))
        self.assertEqual(capability("shell", "sbx@1").get("config"), None)
        text = (V3 / "shell/shell.dockerfile").read_text()
        self.assertIn('ENTRYPOINT ["bash"]', text)
        self.assertIn('CMD ["-l"]', text)

    def test_every_dockerfile_pins_the_same_base_digest(self):
        froms = {path: re.search(r"^FROM (\S+)", path.read_text(), re.M).group(1) for path in V3.glob("*/*.dockerfile")}
        self.assertGreaterEqual(len(froms), 2)   # boxen and shell here; Task 4 adds grok and tightens this to exactly 3
        for path, base in froms.items():
            self.assertRegex(base, r"^docker/sandbox-templates:shell-docker@sha256:[0-9a-f]{64}$", path)
        self.assertEqual(len(set(froms.values())), 1)

class HostGates(unittest.TestCase):
    def setUp(self):
        self.bin = Path(tempfile.mkdtemp()); self.log = self.bin / "calls"
        fake = self.bin / "sbx"
        fake.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$FAKE_LOG"\n'
                        'case "$*" in *"ls --json"*) [[ "${FAKE_LS_EXIT:-0}" == 0 ]] || exit "$FAKE_LS_EXIT"; '
                        'echo \'{"sandboxes":[{"name":"existing-box","id":"sbx_x","status":"running"}]}\' ;; esac\n')
        fake.chmod(0o755)

    def gate(self, body, **env):
        env = dict(os.environ, SBX_BIN=str(self.bin / "sbx"), DOCKER_BIN="true", FAKE_LOG=str(self.log),
                   BOXEN_VALIDATION_DIR=tempfile.mkdtemp(), **env)
        result = subprocess.run(["bash", "-c", "source tests/host/lib.sh; gate_begin probe-test; " + body + "; gate_end"],
                                cwd=ROOT, capture_output=True, text=True, env=env)
        calls = self.log.read_text().splitlines() if self.log.exists() else []
        return result, calls

    def test_gate_library_aggregates_failures(self):
        result, _ = self.gate("check ok true; check bad false; expect two 2 echo 2")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("PASS ok", result.stdout); self.assertIn("FAIL bad", result.stdout); self.assertIn("PASS two", result.stdout)

    def test_expect_requires_exit_zero_and_matching_output(self):
        result, _ = self.gate("expect lying 2 sh -c 'echo 2; exit 7'; expect wrong 2 echo 3; expect fine 2 echo 2")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL lying (exit 7)", result.stdout); self.assertIn("FAIL wrong", result.stdout); self.assertIn("PASS fine", result.stdout)

    def test_an_exhausted_wait_fails_the_gate_even_when_later_checks_pass(self):
        result, _ = self.gate("wait_for never 2 false; check later true")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL never", result.stdout); self.assertIn("PASS later", result.stdout)

    def test_must_ends_the_gate_so_dependent_steps_never_run(self):
        result, _ = self.gate("must first false; check later true")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL first", result.stdout); self.assertNotIn("PASS later", result.stdout)

    def test_gates_get_their_own_state_dir(self):
        result, _ = self.gate('check state test "$BOXEN_STATE_DIR" != "$HOME/.local/state/boxen" -a -d "$BOXEN_STATE_DIR"')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_rejected_claim_stops_everything_against_that_name(self):
        result, calls = self.gate('claim existing-box; check dependent "$SBX_BIN" exec existing-box true')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL claim existing-box (exists)", result.stdout)
        self.assertFalse(any("existing-box" in call and "ls" not in call for call in calls), calls)

    def test_a_failed_listing_is_not_a_free_name(self):
        result, calls = self.gate('claim fresh-box cloud; check dependent "$SBX_BIN" --cloud run --detached --name fresh-box x', FAKE_LS_EXIT="7")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL claim fresh-box (sbx ls failed)", result.stdout)
        self.assertFalse(any("run" in call for call in calls), calls)

    def test_cleanup_removes_only_what_the_gate_made(self):
        result, calls = self.gate('claim fresh-box cloud; claim other-box; made fresh-box cloud; check fine true')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("--cloud rm --force fresh-box", calls)
        self.assertFalse(any("rm" in call and ("other-box" in call or "existing-box" in call) for call in calls), calls)

    def test_create_sandbox_claims_creates_and_registers_for_cleanup(self):
        result, calls = self.gate('create_sandbox new-box cloud -- "$SBX_BIN" --cloud run --detached --name new-box x; check after true')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("--cloud run --detached --name new-box x", calls); self.assertIn("--cloud rm --force new-box", calls)
        self.log.unlink()
        result, calls = self.gate('create_sandbox new-box -- false; check after true')
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("PASS after", result.stdout)
        self.assertFalse(any("rm" in call and "new-box" in call for call in calls), calls)

    def test_every_gate_sources_the_library_and_parses(self):
        gates = sorted((ROOT / "tests/host").glob("*-gate.sh"))
        self.assertTrue(gates)
        for gate in gates:
            with self.subTest(gate=gate.name):
                self.assertIn("source \"$(dirname \"$0\")/lib.sh\"", gate.read_text())
                self.assertEqual(subprocess.run(["bash", "-n", str(gate)]).returncode, 0)

if __name__ == "__main__":
    unittest.main()
