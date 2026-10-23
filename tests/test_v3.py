"""Structural checks on the v3 kits, plus the guest scripts run on the host
against fake tools. sbx validates the kit grammar; these pin Boxen's rules."""
from pathlib import Path
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
V3 = ROOT / "v3"
SYNTAX = "# syntax=docker/sandbox-kit:3"
SCRIPTS = V3 / "boxen/scripts"
GUEST = "/usr/local/share/boxen/"
# sbx's built-in agents; a kit named after one is refused at create.
BUILT_IN_AGENTS = {"claude", "codex", "cursor", "devin", "docker-agent", "gemini", "opencode", "shell"}
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

    def test_no_kit_takes_a_built_in_agent_name(self):
        # sbx refused v3/shell: "agent \"shell\" is already registered".
        for directory in kit_dirs():
            with self.subTest(kit=directory.name):
                self.assertNotIn(directory.name, BUILT_IN_AGENTS)
                for provide in descriptor(directory.name)["provides"]:
                    self.assertNotIn(provide.split("@")[0], BUILT_IN_AGENTS)

    def test_every_dockerfile_pins_the_same_base_digest(self):
        froms = {path: re.search(r"^FROM (\S+)", path.read_text(), re.M).group(1) for path in V3.glob("*/*.dockerfile")}
        self.assertTrue(froms)
        for path, base in froms.items():
            self.assertRegex(base, r"^docker/sandbox-templates:shell-docker@sha256:[0-9a-f]{64}$", path)
        self.assertEqual(len(set(froms.values())), 1)

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

class BoxenWorkload(ScriptCase):
    def run_entry(self, agent=None, *args):
        for tool in ("claude", "codex", "grok", "bash"):
            self.fake(tool, f'echo "{tool} $*"')
        env = dict(os.environ, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
                   BOXEN_ENV_FILE="/nonexistent", BOXEN_PROFILE="/nonexistent")
        env.pop("BOXEN_AGENT", None)
        if agent is not None:
            env["BOXEN_AGENT"] = agent
        # The real bash runs the script; the fake one on PATH is what it execs.
        return subprocess.run([shutil.which("bash"), str(SCRIPTS / "boxen-entry.sh"), *args],
                              env=env, capture_output=True, text=True, timeout=20)

    def test_boxen_is_the_workload_and_owns_the_agents_md_context(self):
        # sbx refuses a mixin that changes a file the workload also changed, and
        # apt changes the same files in any image, so the tools image is the
        # workload and agents come as Docker's mixins.
        data = descriptor("boxen")
        self.assertEqual((data["kind"], data["provides"]), ("workload", ["boxen@1.0.0"]))
        self.assertEqual(capability("boxen", "sbx@1").get("config"), None)
        context = capability("boxen", "agent-context@1")["config"]
        self.assertEqual(context["filename"], "AGENTS.md")
        self.assertIn("boxen shell --with-sudo", " ".join(context["content"].split()))
        self.assertEqual([d.name for d in kit_dirs()], ["boxen"])

    def test_image_starts_as_agent_through_boxen_entry(self):
        text = (V3 / "boxen/boxen.dockerfile").read_text()
        self.assertEqual(re.findall(r"(?m)^USER (\S+)", text)[-1], "agent")
        self.assertEqual(re.findall(r"(?m)^WORKDIR (\S+)", text)[-1], "/home/agent/workspace")
        self.assertIn('ENTRYPOINT ["bash", "/usr/local/share/boxen/boxen-entry.sh"]', text)
        self.assertNotIn("CMD", text)

    def test_entry_starts_the_agent_named_by_boxen_agent(self):
        cases = {"claude": "claude --dangerously-skip-permissions -c",
                 "codex": "codex --dangerously-bypass-approvals-and-sandbox -c",
                 "grok": "grok --yolo --no-auto-update -c",
                 "shell": "bash -l -c", None: "bash -l -c"}
        for agent, expected in cases.items():
            with self.subTest(agent=agent):
                result = self.run_entry(agent, "-c")
                self.assertEqual((result.returncode, result.stdout.strip()), (0, expected), result.stderr)

    def test_entry_refuses_an_unknown_agent(self):
        result = self.run_entry("bogus")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("bogus", result.stderr)

    def test_boxen_keeps_the_v2_core_hosts_on_ubuntu_mirrors(self):
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
        # The scripts change most often, so theirs is the last COPY and RUN-free tail.
        self.assertEqual(re.findall(r"(?m)^COPY .*", text)[-1], "COPY scripts/ /usr/local/share/boxen/")
        self.assertNotIn("RUN", text[text.index("COPY scripts/ /usr/local/share/boxen/"):])
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

    def test_env_file_trusts_mise_config_in_the_workspace(self):
        probe = f'. {SCRIPTS}/env.sh; printf "%s" "$MISE_TRUSTED_CONFIG_PATHS"'
        value = subprocess.run(["sh", "-c", probe], env={"HOME": str(self.directory), "PATH": "/usr/bin:/bin"},
                               capture_output=True, text=True).stdout
        self.assertEqual(value, "/home/agent/workspace")

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

    def test_sudo_verify_needs_sudo_to_say_the_agent_is_not_allowed(self):
        cases = (('echo "User agent is not allowed to run sudo on box."; exit 1', True),
                 ('exit 1', False),                                              # sudo broken: not proof of anything
                 ('echo "User agent may run the following commands on box:"', False))
        for body, ok in cases:
            with self.subTest(body=body):
                self.fake("sudo", body)
                result = self.run_script("sudo-policy.sh", "verify", ok=False)
                self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
                if not ok:
                    self.assertIn("agent", result.stderr)

    def test_check_keeps_cloud_sudo_and_fails_an_unknown_agent(self):
        self.fake("sudo", "exit 0")
        cloud = self.run_script("check.sh", env={"BOXEN_CLOUD": "1", "BOXEN_AGENT": "bogus"}, ok=False).stdout
        self.assertIn("PASS Docker's sudo (cloud sandbox)", cloud)
        self.assertNotIn("No standing sudo", cloud)
        self.assertIn("FAIL agent bogus is not one boxen knows", cloud)
        local = self.run_script("check.sh", env={"BOXEN_AGENT": "shell"}, ok=False).stdout
        self.assertIn("FAIL No standing sudo", local)
        self.assertNotIn("is not one boxen knows", local)

    def test_check_script_uses_the_new_helper_paths(self):
        text = (SCRIPTS / "check.sh").read_text()
        self.assertIn(GUEST + "browser-check.py", text)
        self.assertIn(GUEST + "lazy-check.lua", text)

class BakedTools(unittest.TestCase):
    ROOT_STEPS = ["core-root.sh", "chromium-root.sh", "tailscale-install.sh"]
    USER_STEPS = ["core-user.sh", "fzf-bat.sh", "just.sh", "glow.sh", "mermaid-ascii.sh", "overmind.sh",
                  "cubic.sh", "1pass.sh", "rtk-install.sh", "chromium.sh", "nvchad.sh"]

    def test_dockerfile_runs_every_installer_in_order(self):
        text = (V3 / "boxen/boxen.dockerfile").read_text()
        runs = re.findall(r"^RUN bash " + re.escape(GUEST) + r"([A-Za-z0-9_.-]+)$", text, re.M)
        self.assertEqual(runs, self.ROOT_STEPS + self.USER_STEPS)
        self.assertLess(text.index("tailscale-install.sh"), text.index("USER agent"))
        self.assertGreater(text.index("RUN bash " + GUEST + "nvchad.sh"), text.index("USER agent"))

    def test_pinned_downloads_are_checksummed(self):
        for script in SCRIPTS.glob("*.sh"):
            text = script.read_text()
            with self.subTest(script=script.name):
                self.assertNotIn("@latest", text)
                self.assertNotIn("releases/latest", text)
                if re.findall(r'curl -fsSL "[^"]+" -o', text):
                    self.assertIn("sha256sum -c", text)

    def test_nvchad_steps_are_time_limited_and_find_the_plugin_check(self):
        script = (SCRIPTS / "nvchad.sh").read_text()
        for line in script.replace("\\\n", " ").splitlines():
            with self.subTest(line=line):
                self.assertNotRegex(line, r'^\s*(curl|nvim|npm|git clone) ')
        self.assertIn(GUEST + "lazy-check.lua", script)

    def test_rtk_install_only_installs_the_binary(self):
        text = (SCRIPTS / "rtk-install.sh").read_text()
        self.assertNotIn("rtk init", text)
        self.assertNotIn("claude-rtk.json", text)

    def test_runtime_hosts_are_the_union_of_the_v2_kits(self):
        hosts = set(allowed("boxen"))
        for host in ("api.cubic.dev", "app.cubic.dev", "cubic.dev", "www.cubic.dev", "mcafvrhahbqdwfrtncql.supabase.co",
                     "pypi.org", "files.pythonhosted.org", "hex.pm", "repo.hex.pm", "builds.hex.pm", "elixir-lang.org",
                     "registry.npmmirror.com", "codeberg.org", "cdn.playwright.dev",
                     "playwright.download.prss.microsoft.com", "googlechromelabs.github.io"):
            self.assertIn(host, hosts)
        self.assertFalse({h for h in hosts if "tailscale" in h or "1password" in h or "agilebits" in h or "gist." in h}, hosts)

    def test_check_script_checks_every_baked_tool_unconditionally(self):
        text = (SCRIPTS / "check.sh").read_text()
        for binary in ("fzf", "bat", "just", "glow", "mermaid-ascii", "overmind", "rtk", "nvim", "op", "tailscale",
                       "google-chrome", "chromedriver", "cubic"):
            self.assertRegex(text, r"\b" + re.escape(binary) + r"\b")
        head = text.split("BOXEN_PLUGINS")[0]
        for binary in ("fzf", "nvim", "op", "google-chrome"):
            self.assertIn(binary, head)
        self.assertIn("BOXEN_AGENT", text)


class HostGates(unittest.TestCase):
    def setUp(self):
        self.bin = Path(tempfile.mkdtemp()); self.log = self.bin / "calls"
        fake = self.bin / "sbx"
        # Lists existing-box plus every name in FAKE_EXTRA (id sbx_<name>); ls fails
        # with FAKE_LS_EXIT, or once the file FAKE_LS_FAIL_FLAG exists.
        fake.write_text(r"""#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$*" in
  *"ls --json"*)
    [[ "${FAKE_LS_EXIT:-0}" == 0 ]] || exit "$FAKE_LS_EXIT"
    [[ ! -e "$FAKE_LS_FAIL_FLAG" ]] || exit 7
    rows='{"name":"existing-box","id":"sbx_x","status":"running"}'
    if [[ -f "$FAKE_EXTRA" ]]; then
      while read -r n; do [[ -z "$n" ]] || rows="$rows,{\"name\":\"$n\",\"id\":\"sbx_$n\",\"status\":\"running\"}"; done < "$FAKE_EXTRA"
    fi
    printf '{"sandboxes":[%s]}\n' "$rows" ;;
esac
""")
        fake.chmod(0o755)
        self.extra = self.bin / "extra"

    def gate(self, body, **env):
        env = dict(os.environ, SBX_BIN=str(self.bin / "sbx"), DOCKER_BIN="true", FAKE_LOG=str(self.log),
                   FAKE_EXTRA=str(self.bin / "extra"), FAKE_LS_FAIL_FLAG=str(self.bin / "ls-fails"),
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
        # fresh-box is free at the claim and listed once the gate has made it.
        result, calls = self.gate('claim fresh-box cloud; claim other-box; echo fresh-box >> "$FAKE_EXTRA"; '
                                  'made fresh-box cloud; check fine true')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("--cloud rm --force fresh-box", calls)
        self.assertFalse(any("rm" in call and ("other-box" in call or "existing-box" in call) for call in calls), calls)

    def test_create_sandbox_claims_creates_and_registers_for_cleanup(self):
        result, calls = self.gate('create_sandbox new-box cloud -- sh -c \'echo new-box >> "$FAKE_EXTRA"; "$SBX_BIN" --cloud run --detached --name new-box x\'; check after true')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("--cloud run --detached --name new-box x", calls); self.assertIn("--cloud rm --force new-box", calls)
        self.log.unlink(); self.extra.unlink()
        result, calls = self.gate('create_sandbox new-box -- false; check after true')
        self.assertEqual(result.returncode, 1)
        self.assertIn("PASS claim new-box", result.stdout)          # the name was free, so the create really ran
        self.assertIn("FAIL create new-box (exit 1)", result.stdout)
        self.assertNotIn("PASS after", result.stdout)
        self.assertFalse(any("rm" in call and "new-box" in call for call in calls), calls)

    def test_a_failed_create_that_left_a_sandbox_is_still_removed(self):
        result, calls = self.gate('create_sandbox half-box cloud -- sh -c \'echo half-box >> "$FAKE_EXTRA"; exit 3\'; check after true')
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("PASS after", result.stdout)
        self.assertIn("--cloud rm --force half-box", calls)

    def test_cleanup_keeps_a_cloud_sandbox_it_cannot_identify(self):
        result, calls = self.gate('made ghost-box cloud; check fine true')          # never listed: no id recorded
        self.assertIn("NOT removing ghost-box", result.stdout)
        self.assertFalse(any("rm" in call for call in calls), calls)
        self.extra.write_text("lost-box\n"); self.log.unlink()
        result, calls = self.gate('made lost-box cloud; touch "$FAKE_LS_FAIL_FLAG"; check fine true')   # listing fails at exit
        self.assertIn("NOT removing lost-box", result.stdout)
        self.assertFalse(any("rm" in call for call in calls), calls)

    def test_agent_mixins_are_pinned_once_by_tag_and_digest(self):
        out = subprocess.run(["bash", "-c", "source tests/host/pins.sh; for a in claude codex grok; do "
                              "printf '%s %s %s\\n' \"$a\" \"$(mixin_ref $a)\" \"$(mixin_digest $a)\"; done"],
                             cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        for line in out.stdout.splitlines():
            agent, ref, digest = line.split()
            with self.subTest(agent=agent):
                self.assertRegex(ref, rf"^docker\.io/docker/sbx-kit-{agent}-mixin:[0-9][0-9.]*$")
                self.assertRegex(digest, r"^sha256:[0-9a-f]{64}$")
        for gate in ("compose-gate.sh", "cloud-compose-gate.sh"):
            with self.subTest(gate=gate):
                text = (ROOT / "tests/host" / gate).read_text()
                self.assertIn('source "$(dirname "$0")/pins.sh"', text)
                self.assertNotIn("sbx-kit-claude:", text)   # Docker's agent workloads are no longer used

    def test_host_scripts_guard_array_expansions_for_bash_3_2(self):
        # Under set -u, Bash 3.2 treats "${a[@]}" of an empty array as unbound.
        guarded = re.compile(r'\$\{(\w+)\[@\]\+"\$\{\1\[@\]\}"\}')
        for script in sorted((ROOT / "tests/host").glob("*.sh")):
            with self.subTest(script=script.name):
                self.assertEqual(re.findall(r"\$\{\w+\[@\]\}", guarded.sub("", script.read_text())), [])

    def test_every_gate_sources_the_library_and_parses(self):
        gates = sorted((ROOT / "tests/host").glob("*-gate.sh"))
        self.assertTrue(gates)
        for gate in gates:
            with self.subTest(gate=gate.name):
                self.assertIn("source \"$(dirname \"$0\")/lib.sh\"", gate.read_text())
                self.assertEqual(subprocess.run(["bash", "-n", str(gate)]).returncode, 0)

if __name__ == "__main__":
    unittest.main()
