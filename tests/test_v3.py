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

    def test_credentials_inject_only_into_their_own_kits_hosts(self):
        # sbx checks each kit alone: "inject domain \"github.com\" is not in the
        # network policy's runtime allow list", though boxen allowed it.
        for directory in kit_dirs():
            for cred in capabilities(directory.name, "credential@1"):
                for rule in cred["config"]["apiKey"].get("inject", []):
                    with self.subTest(kit=directory.name, domain=rule["domain"]):
                        self.assertIn(rule["domain"], allowed(directory.name))

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
        self.assertIn("bxn shell --with-sudo", " ".join(context["content"].split()))
        self.assertEqual([d.name for d in kit_dirs() if descriptor(d.name)["kind"] == "workload"], ["boxen"])

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
        # v2's kits/core allow list as it stood at the cutover.
        core = ["github.com", "api.github.com", "raw.githubusercontent.com", "objects.githubusercontent.com",
                "release-assets.githubusercontent.com", "codeload.github.com", "archive.ubuntu.com:80",
                "security.ubuntu.com:80", "ports.ubuntu.com:80", "archive.ubuntu.com:443", "security.ubuntu.com:443",
                "ports.ubuntu.com:443", "download.docker.com", "cli.github.com", "nodejs.org", "registry.npmjs.org",
                "go.dev", "dl.google.com", "proxy.golang.org", "sum.golang.org", "storage.googleapis.com",
                "api.mason-registry.dev", "www.skills.sh", "mise.en.dev", "d5l0dvt14r5h8.cloudfront.net",
                "d2glxqk2uabbnd.cloudfront.net", "deno.land", "mcp.supabase.com"]
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
        # A child process reads it, as mise does, so a plain assignment would fail.
        probe = f'. {SCRIPTS}/env.sh; sh -c \'printf "%s" "$MISE_TRUSTED_CONFIG_PATHS"\''
        value = subprocess.run(["sh", "-c", probe], env={"HOME": str(self.directory), "PATH": "/usr/bin:/bin"},
                               capture_output=True, text=True).stdout
        self.assertEqual(value, "/home/agent/workspace")

    def test_proxy_variables_are_never_exported_by_the_image(self):
        for script in SCRIPTS.glob("*.sh"):
            with self.subTest(script=script.name):
                self.assertNotIn("export HTTP_PROXY=", script.read_text())
                self.assertNotIn("export HTTPS_PROXY=", script.read_text())

    def test_sudo_policy_is_an_install_hook(self):
        # Boxes lose standing sudo at create, so the image ships Docker's sudoers untouched.
        self.assertNotIn("sudo-policy.sh", (V3 / "boxen/boxen.dockerfile").read_text())
        hook = next(h for h in hooks("boxen", "install") if "sudo-policy.sh" in command_text(h))
        self.assertEqual(hook["user"], "0")
        self.assertNotIn("env", hook)
        text = (SCRIPTS / "sudo-policy.sh").read_text()
        self.assertIn("boxen-sudo-session", text)
        self.assertNotIn("BOXEN_CLOUD", text)

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

    def test_check_fails_standing_sudo_and_an_unknown_agent(self):
        self.fake("sudo", "exit 0")
        out = self.run_script("check.sh", env={"BOXEN_AGENT": "bogus"}, ok=False).stdout
        self.assertIn("FAIL No standing sudo", out)
        self.assertIn("FAIL agent bogus is not one boxen knows", out)
        out = self.run_script("check.sh", env={"BOXEN_AGENT": "shell"}, ok=False).stdout
        self.assertNotIn("is not one boxen knows", out)

    def test_check_script_uses_the_new_helper_paths(self):
        text = (SCRIPTS / "check.sh").read_text()
        self.assertIn(GUEST + "browser-check.py", text)
        self.assertIn(GUEST + "lazy-check.lua", text)

class BakedTools(ScriptCase):
    ROOT_STEPS = ["core-root.sh", "chromium-root.sh", "tailscale-install.sh"]
    USER_STEPS = ["core-user.sh", "fzf-bat.sh", "just.sh", "glow.sh", "mermaid-ascii.sh", "overmind.sh",
                  "cubic.sh", "1pass.sh", "rtk-install.sh", "chromium.sh", "nvchad.sh", "gh-stack.sh"]

    def test_dockerfile_runs_every_installer_in_order(self):
        text = (V3 / "boxen/boxen.dockerfile").read_text()
        runs = re.findall(r"^RUN bash " + re.escape(GUEST) + r"([A-Za-z0-9_.-]+)$", text, re.M)
        self.assertEqual(runs, self.ROOT_STEPS + self.USER_STEPS + ["skills-install.sh"])
        self.assertLess(text.index("tailscale-install.sh"), text.index("USER agent"))
        self.assertGreater(text.index("RUN bash " + GUEST + "nvchad.sh"), text.index("USER agent"))

    def test_botfight_comes_from_the_skills_main_branch_after_the_slow_steps(self):
        # A new commit on main rebuilds from this step on, so it sits after the installers.
        text = (V3 / "boxen/boxen.dockerfile").read_text()
        add = text.index("ADD https://github.com/MixTapeSoftware/skills.git#main /usr/local/share/boxen/skills\n")
        self.assertGreater(add, text.index("RUN bash " + GUEST + "nvchad.sh"))
        self.assertLess(add, text.index("RUN bash " + GUEST + "skills-install.sh"))
        self.assertEqual(text[:add].rsplit("USER ", 1)[1].split("\n")[0], "root")

    def test_skills_install_links_every_skill_where_each_agent_reads_it(self):
        # The skills repository's main branch, and gh stack's pinned checkout, in paths with spaces.
        source = Path(tempfile.mkdtemp(prefix="skills repo ", dir=self.directory))
        pinned = Path(tempfile.mkdtemp(prefix="gh stack ", dir=self.directory))
        for root, name in ((source, "botfight"), (source, "other"), (pinned, "gh-stack")):
            (root / name).mkdir()
            (root / name / "SKILL.md").write_text(f"---\nname: {name}\n---\n")
        (source / "README.md").write_text("not a skill\n")
        (pinned / "gh-stack/references").mkdir()
        (pinned / "gh-stack/references/commands.md").write_text("commands\n")
        claude, shared = self.directory / "etc/claude-code/.claude/skills", self.directory / "home/.agents/skills"
        env = dict(os.environ, BOXEN_SKILLS_SRC=f"{source}:{pinned}", BOXEN_CLAUDE_SKILLS=str(claude),
                   BOXEN_AGENT_HOME=str(self.directory / "home"), BOXEN_AGENT_OWNER=f"{os.getuid()}:{os.getgid()}")
        for _ in range(2):
            result = subprocess.run(["bash", str(SCRIPTS / "skills-install.sh")], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        for target in (claude, shared):
            self.assertEqual(sorted(p.name for p in target.iterdir()), ["botfight", "gh-stack", "other"], target)
            self.assertTrue((target / "botfight/SKILL.md").is_file(), target)
            self.assertEqual(sorted(p.name for p in (target / "botfight").iterdir()), ["SKILL.md"])
            self.assertTrue((target / "gh-stack/references/commands.md").is_file(), target)
        # A box missing either required skill fails the build.
        for required in (source / "botfight/SKILL.md", pinned / "gh-stack/SKILL.md"):
            text = required.read_text()
            required.unlink()
            fresh = Path(tempfile.mkdtemp(dir=self.directory))
            result = subprocess.run(["bash", str(SCRIPTS / "skills-install.sh")], capture_output=True, text=True,
                                    env=dict(env, BOXEN_CLAUDE_SKILLS=str(fresh / "skills"), BOXEN_AGENT_HOME=str(fresh / "home")))
            self.assertNotEqual(result.returncode, 0, required)
            required.write_text(text)
        script = (SCRIPTS / "skills-install.sh").read_text()
        # Claude Code's system-wide folder, and the one Codex and Grok both read.
        self.assertIn("/etc/claude-code/.claude/skills", script)
        self.assertIn('/.agents/skills', script)
        self.assertNotIn("/etc/codex/skills", script)

    def test_check_script_checks_the_botfight_skill_for_every_agent(self):
        text = (SCRIPTS / "check.sh").read_text()
        for skill in ("botfight", "gh-stack"):
            self.assertIn(f"/etc/claude-code/.claude/skills/{skill}/SKILL.md", text)
            self.assertIn(f"$HOME/.agents/skills/{skill}/SKILL.md", text)
        self.assertIn("gh stack --version", text)
        self.assertNotIn("/etc/codex/skills", text)

    def test_gh_stack_is_one_pinned_release_with_its_own_skill(self):
        script = (SCRIPTS / "gh-stack.sh").read_text()
        self.assertIn("version=v0.2.1", script)
        self.assertIn('"https://github.com/github/gh-stack/releases/download/$version/linux-$arch"', script)
        self.assertEqual(len(re.findall(r"checksum=[0-9a-f]{64}\b", script)), 2)   # amd64 and arm64
        self.assertIn("sha256sum -c", script)
        # gh's own manifest for a pinned install, so gh extension upgrade leaves it alone.
        self.assertIn("ispinned: true", script)
        self.assertIn("/gh/extensions/gh-stack", script)
        # The skill comes from the commit the pinned release was built from.
        commit = re.search(r"\bcommit ([0-9a-f]{40})\b", script)[1]
        text = (V3 / "boxen/boxen.dockerfile").read_text()
        add = text.index(f"ADD https://github.com/github/gh-stack.git#{commit} /usr/local/share/boxen/gh-stack\n")
        self.assertGreater(add, text.index("RUN bash " + GUEST + "gh-stack.sh"))
        self.assertLess(add, text.index("RUN bash " + GUEST + "skills-install.sh"))
        self.assertEqual(text[:add].rsplit("USER ", 1)[1].split("\n")[0], "root")
        self.assertIn("/usr/local/share/boxen/gh-stack/skills", (SCRIPTS / "skills-install.sh").read_text())
        # The release is pinned, so its upgrade notices would only ask for an upgrade gh refuses.
        self.assertIn("export GH_STACK_NO_UPDATE_NOTIFIER=1", (SCRIPTS / "env.sh").read_text())

    def test_pinned_downloads_are_checksummed(self):
        for script in SCRIPTS.glob("*.sh"):
            text = script.read_text()
            with self.subTest(script=script.name):
                self.assertNotIn("@latest", text)
                self.assertNotIn("releases/latest", text)
                if re.findall(r'curl -fsSL "[^"]+" -o', text):
                    self.assertIn("sha256sum -c", text)

    def test_only_the_known_vendor_installers_are_piped_to_a_shell(self):
        # cubic's and RTK's installers are unpinned on purpose, as in v2; any
        # other download piped to a shell runs unverified code at build time.
        piped = sorted(s.name for s in SCRIPTS.glob("*.sh")
                       if re.search(r"curl [^|\n]*\|\s*(?:\w+=\S+\s+)*(?:ba)?sh\b", s.read_text()))
        self.assertEqual(piped, ["cubic.sh", "rtk-install.sh"])

    def test_an_installer_step_copies_only_what_its_script_uses(self):
        # Runtime-only files come with the last COPY, so editing one never
        # rebuilds an installer step.
        text = (V3 / "boxen/boxen.dockerfile").read_text()
        for files, script in re.findall(r"^COPY (?:--chown=\S+ )?((?:scripts/\S+ )+)\S+\nRUN bash " + re.escape(GUEST) + r"(\S+)$", text, re.M):
            body = (SCRIPTS / script).read_text()
            for extra in (f[len("scripts/"):] for f in files.split() if f != "scripts/" + script):
                with self.subTest(step=script, file=extra):
                    self.assertIn(extra, body)

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
        # Exactly the union: a host added or dropped here is a change to the
        # sandbox's network boundary and has to be made on purpose.
        # v2's core, cubic, nvchad and chromium allow lists as they stood at the cutover.
        union = {
            "api.cubic.dev", "api.github.com", "api.mason-registry.dev", "app.cubic.dev",
            "archive.ubuntu.com:443", "archive.ubuntu.com:80", "builds.hex.pm",
            "cdn.playwright.dev", "cli.github.com", "codeberg.org", "codeload.github.com",
            "cubic.dev", "d2glxqk2uabbnd.cloudfront.net", "d5l0dvt14r5h8.cloudfront.net",
            "deno.land", "dl.google.com", "download.docker.com", "elixir-lang.org",
            "files.pythonhosted.org", "github.com", "go.dev", "googlechromelabs.github.io",
            "hex.pm", "mcafvrhahbqdwfrtncql.supabase.co", "mcp.supabase.com", "mise.en.dev",
            "nodejs.org", "objects.githubusercontent.com", "playwright.download.prss.microsoft.com",
            "ports.ubuntu.com:443", "ports.ubuntu.com:80", "proxy.golang.org", "pypi.org",
            "raw.githubusercontent.com", "registry.npmjs.org", "registry.npmmirror.com",
            "release-assets.githubusercontent.com", "repo.hex.pm", "security.ubuntu.com:443",
            "security.ubuntu.com:80", "storage.googleapis.com", "sum.golang.org", "www.cubic.dev",
            "www.skills.sh"
        }
        self.assertEqual(set(allowed("boxen")), union)

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
        # Lists existing-box plus every "name [status]" line in FAKE_EXTRA (id
        # sbx_<name>, running unless given); ls prints FAKE_LS_BODY instead when
        # set, and fails with FAKE_LS_EXIT, or once the file FAKE_LS_FAIL_FLAG exists.
        # A local detached run exits with FAKE_RUN_EXIT.
        fake.write_text(r"""#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$*" in
  "run -d"*) exit "${FAKE_RUN_EXIT:-0}" ;;
  *"ls --json"*)
    [[ "${FAKE_LS_EXIT:-0}" == 0 ]] || exit "$FAKE_LS_EXIT"
    [[ ! -e "$FAKE_LS_FAIL_FLAG" ]] || exit 7
    [[ -z "${FAKE_LS_BODY:-}" ]] || { printf '%s\n' "$FAKE_LS_BODY"; exit 0; }
    rows='{"name":"existing-box","id":"sbx_x","status":"running"}'
    if [[ -f "$FAKE_EXTRA" ]]; then
      while read -r n s; do [[ -z "$n" ]] || rows="$rows,{\"name\":\"$n\",\"id\":\"sbx_$n\",\"status\":\"${s:-running}\"}"; done < "$FAKE_EXTRA"
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
        result, calls = self.gate('claim fresh-box; check dependent "$SBX_BIN" run -d --name fresh-box x', FAKE_LS_EXIT="7")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL claim fresh-box (sbx ls failed)", result.stdout)
        self.assertFalse(any("run" in call for call in calls), calls)

    def test_cleanup_removes_only_what_the_gate_made(self):
        # fresh-box is free at the claim and listed once the gate has made it.
        result, calls = self.gate('claim fresh-box; claim other-box; echo fresh-box >> "$FAKE_EXTRA"; '
                                  'made fresh-box; check fine true')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("rm --force fresh-box", calls)
        self.assertFalse(any("rm" in call and ("other-box" in call or "existing-box" in call) for call in calls), calls)

    def test_create_sandbox_claims_creates_and_registers_for_cleanup(self):
        result, calls = self.gate('create_sandbox new-box -- sh -c \'echo new-box >> "$FAKE_EXTRA"; "$SBX_BIN" run -d --name new-box x\'; check after true')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("run -d --name new-box x", calls); self.assertIn("rm --force new-box", calls)
        self.log.unlink(); self.extra.unlink()
        result, calls = self.gate('create_sandbox new-box -- false; check after true')
        self.assertEqual(result.returncode, 1)
        self.assertIn("PASS claim new-box", result.stdout)          # the name was free, so the create really ran
        self.assertIn("FAIL create new-box (exit 1)", result.stdout)
        self.assertNotIn("PASS after", result.stdout)
        self.assertFalse(any("rm" in call and "new-box" in call for call in calls), calls)

    def test_a_failed_create_that_left_a_sandbox_is_still_removed(self):
        result, calls = self.gate('create_sandbox half-box -- sh -c \'echo half-box >> "$FAKE_EXTRA"; exit 3\'; check after true')
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("PASS after", result.stdout)
        self.assertIn("rm --force half-box", calls)

    def test_borrow_starts_only_a_listed_stopped_sandbox_and_never_makes_one(self):
        # sbx run --name with a name that is not listed would make a sandbox.
        for body, env, failure in (('borrow ghost-box', {}, "FAIL borrow ghost-box (not listed"),
                                   ('borrow existing-box', {"FAKE_LS_EXIT": "7"}, "FAIL borrow existing-box (sbx ls failed)"),
                                   ('borrow existing-box', {"FAKE_LS_BODY": "not json"}, "FAIL borrow existing-box (unreadable listing)"),
                                   ('borrow existing-box', {"FAKE_LS_BODY": '{"sandboxes":[]}'}, "FAIL borrow existing-box (not listed"),
                                   # Only running and stopped are known states to leave it in.
                                   ('borrow existing-box', {"FAKE_LS_BODY": '{"sandboxes":[{"name":"existing-box"}]}'},
                                    "FAIL borrow existing-box (status <none>"),
                                   ('borrow existing-box', {"FAKE_LS_BODY": '{"sandboxes":[{"name":"existing-box","status":"starting"}]}'},
                                    "FAIL borrow existing-box (status starting")):
            with self.subTest(body=body, env=env):
                if self.log.exists():
                    self.log.unlink()
                result, calls = self.gate(body + '; check after true', **env)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(failure, result.stdout)
                self.assertNotIn("PASS after", result.stdout)
                self.assertFalse(any("run" in call or "rm" in call or "stop" in call for call in calls), calls)
        # A running sandbox is used as it is; a stopped one is started and marked
        # so the gate can stop it again. Neither is ever removed.
        self.log.unlink()
        result, calls = self.gate('borrow existing-box; echo "borrowed=$GATE_BORROWED"')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("borrowed=0", result.stdout)
        self.assertFalse(any("run" in call or "rm" in call for call in calls), calls)
        self.extra.write_text("old-box stopped\n"); self.log.unlink()
        result, calls = self.gate('borrow old-box; echo "borrowed=$GATE_BORROWED"')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS start old-box", result.stdout); self.assertIn("borrowed=1", result.stdout)
        self.assertIn("run -d --name old-box", calls)
        self.assertFalse(any("rm" in call for call in calls), calls)
        # A failed start ends the gate: a later sbx exec would start it unrecorded.
        self.log.unlink()
        result, calls = self.gate('borrow old-box; check after true', FAKE_RUN_EXIT="3")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL start old-box (exit 3)", result.stdout)
        self.assertNotIn("PASS after", result.stdout)

    def test_the_launcher_gate_borrows_the_old_sandbox(self):
        text = (ROOT / "tests/host/launcher-gate.sh").read_text()
        self.assertIn('borrow "$BOXEN_OLD_SANDBOX"', text)
        self.assertNotIn("sbx run", text)

    def test_agent_mixins_are_pinned_once_by_tag_and_digest(self):
        out = subprocess.run(["bash", "-c", "source lib/pins.sh; for a in claude codex grok; do "
                              "printf '%s %s %s\\n' \"$a\" \"$(mixin_ref $a)\" \"$(mixin_digest $a)\"; done"],
                             cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        for line in out.stdout.splitlines():
            agent, ref, digest = line.split()
            with self.subTest(agent=agent):
                self.assertRegex(ref, rf"^docker\.io/docker/sbx-kit-{agent}-mixin:[0-9][0-9.]*$")
                self.assertRegex(digest, r"^sha256:[0-9a-f]{64}$")
        # The launcher and every gate read one set of pins.
        self.assertFalse((ROOT / "tests/host/pins.sh").exists())
        for gate in sorted((ROOT / "tests/host").glob("*-gate.sh")):
            text = gate.read_text()
            if "mixin_ref" not in text:
                continue
            with self.subTest(gate=gate.name):
                self.assertIn('source "$(dirname "$0")/../../lib/pins.sh"', text)
                self.assertNotIn("sbx-kit-claude:", text)   # Docker's agent workloads are no longer used

    def test_smoke_runs_cover_every_agent_through_the_v3_launcher(self):
        smoke = (ROOT / "tests/workload-smoke.sh").read_text()
        for v2 in ("kits/", "agents/", "kit add", "template ls"):
            self.assertNotIn(v2, smoke)
        self.assertIn("shell|claude|codex|grok", smoke)
        self.assertIn('"$project/bxn" create', smoke)
        gate = (ROOT / "tests/host/smoke-gate.sh").read_text()
        self.assertIn("for agent in shell claude codex grok", gate)
        self.assertIn("for rtk in rtk nortk", gate)

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

class Mixins(ScriptCase):
    NAMES = ["workspace", "tailscale", "gh-auth", "1pass", "rtkplus-claude", "rtkplus-codex"]

    def test_mixins_are_declaration_only_and_sit_on_boxen(self):
        for name in self.NAMES:
            with self.subTest(kit=name):
                self.assertFalse((V3 / name / f"{name}.dockerfile").exists())
                data = descriptor(name)
                self.assertEqual(data["kind"], "mixin")
                self.assertEqual(data["provides"], [f"boxen-{name}@1.0.0"])
                self.assertIn("boxen >= 1.0.0", data["requires"])

    def test_first_launch_setup_is_an_install_hook(self):
        for name, script in (("workspace", "workspace.sh"), ("gh-auth", "gh-auth.sh"),
                             ("rtkplus-claude", "rtk-claude-hook.sh"), ("rtkplus-codex", "rtk-codex-hook.sh")):
            with self.subTest(kit=name):
                install = hooks(name, "install")
                self.assertEqual(len(install), 1)
                self.assertIn(GUEST + script, command_text(install[0]))
                self.assertEqual(hooks(name, "startup"), [])
        self.assertEqual(hooks("workspace", "install")[0]["user"], "0")
        self.assertEqual(hooks("gh-auth", "install")[0]["user"], "1000")

    def test_rtk_mixins_require_their_agent(self):
        self.assertIn("claude >= 2.0.0", descriptor("rtkplus-claude")["requires"])
        self.assertIn("codex >= 0.100.0", descriptor("rtkplus-codex")["requires"])
        self.assertEqual(hooks("rtkplus-claude", "install")[0]["user"], "1000")
        self.assertEqual(hooks("rtkplus-codex", "install")[0]["user"], "1000")

    def test_tailscale_daemon_and_hosts(self):
        hook = hooks("tailscale", "startup")[0]
        self.assertEqual(hook["user"], "0")
        self.assertTrue(hook["background"])
        install = hooks("tailscale", "install")
        self.assertEqual(len(install), 1)
        self.assertEqual((install[0]["user"], install[0]["env"]), ("0", ["BOXEN_SERVE_PRESET"]))
        self.assertIn("/etc/boxen/serve-preset", command_text(install[0]))
        # tailscale serve --https fetches the node's certificate from Let's Encrypt itself.
        self.assertEqual(
            allowed("tailscale"),
            ["tailscale.com", "*.tailscale.com", "*.tailscale.io", "acme-v02.api.letsencrypt.org"],
        )

    def test_gh_auth_credential_is_proxy_managed_within_its_allow_list(self):
        cred = capability("gh-auth", "credential@1")
        self.assertTrue(cred["optional"])
        config = cred["config"]
        self.assertEqual(config["service"], "github")
        self.assertEqual(config["phase"], ["runtime"])
        self.assertEqual(config["apiKey"]["name"], "GH_TOKEN")
        self.assertTrue(config["apiKey"]["proxyManaged"])
        domains = {rule["domain"] for rule in config["apiKey"]["inject"]}
        self.assertEqual(domains, {"github.com", "api.github.com", "gist.github.com"})
        self.assertTrue(domains <= set(allowed("gh-auth")))

    def test_1pass_declares_hosts_only(self):
        self.assertEqual(allowed("1pass"), ["cache.agilebits.com", "*.1password.com", "*.1password.eu", "*.1password.ca"])
        self.assertEqual([c["type"].rsplit("/", 1)[1] for c in descriptor("1pass")["capabilities"]], ["network-policy@2"])

    def test_workspace_script_creates_links_and_preserves(self):
        root = self.directory / "fs"
        (root / "home/agent").mkdir(parents=True)
        env = {"BOXEN_FS_ROOT": str(root)}
        self.run_script("workspace.sh", env=env)
        self.assertTrue((root / "home/agent/workspace").is_dir())
        self.assertEqual(os.readlink(root / "workspace"), "/home/agent/workspace")
        (root / "home/agent/workspace/keep").write_text("x")
        self.run_script("workspace.sh", env=env)
        self.assertEqual((root / "home/agent/workspace/keep").read_text(), "x")
        os.unlink(root / "workspace"); (root / "workspace").mkdir()
        self.run_script("workspace.sh", env=env)
        self.assertFalse(os.path.islink(root / "workspace"))

    def test_rtk_claude_hook_merges_without_touching_other_hooks(self):
        claude = self.directory / ".claude"; claude.mkdir()
        settings = claude / "settings.json"
        before = {"model": "opus", "permissions": {"defaultMode": "bypassPermissions"}, "hooks": {"PreToolUse": [
            {"matcher": "Bash", "hooks": [{"type": "command", "command": "audit"}, {"type": "command", "command": "rtk hook claude"}]},
            {"matcher": "Write", "hooks": [{"type": "command", "command": "fmt"}]}],
            "Stop": [{"hooks": [{"type": "command", "command": "notify"}]}]}}
        settings.write_text(json.dumps(before))
        self.run_script("rtk-claude-hook.sh"); self.run_script("rtk-claude-hook.sh")
        after = json.loads(settings.read_text())
        self.assertEqual(after["model"], "opus")
        self.assertEqual(after["permissions"], before["permissions"])
        self.assertEqual(after["hooks"]["Stop"], before["hooks"]["Stop"])
        commands = [h["command"] for entry in after["hooks"]["PreToolUse"] for h in entry["hooks"]]
        self.assertEqual(commands.count("rtk hook claude"), 1)
        self.assertEqual([c for c in commands if c != "rtk hook claude"], ["audit", "fmt"])
        self.assertEqual([m.get("matcher") for m in after["hooks"]["PreToolUse"]], ["Bash", "Write", "Bash"])
        self.assertFalse(list(claude.glob("settings.*.tmp")))

    def test_rtk_claude_hook_handles_missing_and_broken_settings(self):
        claude = self.directory / ".claude"; claude.mkdir()
        self.run_script("rtk-claude-hook.sh")
        self.assertIn("rtk hook claude", (claude / "settings.json").read_text())
        (claude / "settings.json").write_text("{not json")
        result = self.run_script("rtk-claude-hook.sh", ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((claude / "settings.json").read_text(), "{not json")
        self.assertFalse(list(claude.glob("settings.*.tmp")))

    def test_rtk_codex_hook_runs_rtk_init(self):
        self.fake("rtk", 'echo "rtk $*" >> "$HOME/calls"')
        self.run_script("rtk-codex-hook.sh")
        self.assertEqual((self.directory / "calls").read_text().strip(), "rtk init --global --codex")

    def test_no_identity_or_token_is_bundled(self):
        for path in V3.rglob("*"):
            if path.is_file():
                text = path.read_text(errors="ignore")
                self.assertNotEqual(path.name, "tailscaled.state")
                self.assertNotRegex(text, r"tskey-auth-[A-Za-z0-9]+")
                self.assertNotIn("export OP_SERVICE_ACCOUNT_TOKEN=", text)

class Launcher(unittest.TestCase):
    def test_plugin_list_matches_the_launcher(self):
        cli = (ROOT / "lib/cli.sh").read_text()
        plugins = re.search(r'^PLUGINS="([^"]+)"', cli, re.M)[1].split()
        kits = re.search(r'^KITS="([^"]+)"', cli, re.M)[1].split()
        listed = [line.split("\t")[0] for line in (ROOT / "plugins.tsv").read_text().splitlines()[1:]]
        self.assertEqual(listed, plugins)
        # Every selectable mixin is a kit; rtkplus stands for the per-agent pair.
        expected = {d.name for d in kit_dirs()} - {"boxen", "workspace", "rtkplus-claude", "rtkplus-codex"} | {"rtkplus"}
        self.assertEqual(set(kits), expected)

    def test_plugin_descriptions_promise_nothing_the_mixins_lack(self):
        # No Boxen mixin declares a volume, and every tool is in the image already.
        for line in (ROOT / "plugins.tsv").read_text().splitlines()[1:]:
            with self.subTest(plugin=line.split("\t")[0]):
                self.assertNotIn("volume", line)
                self.assertNotIn("CLI", line)

class Cutover(unittest.TestCase):
    def test_v2_kits_and_validator_are_gone(self):
        for path in ("kits", "agents", "tests/validator", "tests/validate-upstream.sh", "tests/test_kits.py", "cloud"):
            self.assertFalse((ROOT / path).exists(), path)
        text = (ROOT / "README.md").read_text()
        self.assertNotIn("kits-v2", text)
        self.assertNotIn("sbx kit add", text)
        self.assertNotIn("in progress", text)
        self.assertIn("v3/boxen", text)
        self.assertIn("https://docs.docker.com/ai/sandboxes/customize/", text)
        self.assertIn("## Docker Cloud", text)

    def test_guest_script_tests_run_the_v3_copies(self):
        for test in ("test_agent_login.py", "test_tailscale.py"):
            with self.subTest(test=test):
                text = (ROOT / "tests" / test).read_text()
                self.assertNotIn("kits/", text)
                self.assertIn("v3/boxen/scripts/", text)

    def test_only_the_launcher_fallback_names_the_old_guest_path(self):
        for path in [ROOT / "bxn", ROOT / "install", *sorted((ROOT / "lib").glob("*.sh"))]:
            for number, line in enumerate(path.read_text().splitlines(), 1):
                with self.subTest(path=path.name, line=number):
                    self.assertNotRegex(line, r"(?<![./\w])(kits|agents)/")
                    if ".local/share/boxen" in line and not line.lstrip().startswith("#"):
                        self.assertIn("/usr/local/share/boxen/", line)   # guest_script's probe: v3 first, then pre-v3

if __name__ == "__main__":
    unittest.main()
