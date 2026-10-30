"""Boxen's guest scripts, which run inside a Sprite, run here on the host
against fake tools."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GUEST = ROOT / "guest"
GUEST_DIR = "/usr/local/share/boxen/"


class ScriptCase(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="boxen-guest-test-")
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
        result = subprocess.run(["bash", str(GUEST / script), *args], env=full, capture_output=True, text=True, timeout=20)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return result


class Environment(ScriptCase):
    def source_env(self, extra=""):
        script = f'. {GUEST / "env.sh"}; . {GUEST / "env.sh"}; {extra}'
        return subprocess.run(["sh", "-c", script], capture_output=True, text=True,
                              env=dict(os.environ, HOME=str(self.directory), PATH="/usr/bin:/bin"))

    def test_env_file_is_idempotent_and_reads_bxn_env(self):
        (self.directory / ".config/boxen").mkdir(parents=True)
        (self.directory / ".config/boxen/env.sh").write_text("export FROM_BXN_ENV=yes\n")
        out = self.source_env('printf "%s\\n%s" "$PATH" "$FROM_BXN_ENV"').stdout.splitlines()
        path = out[0].split(":")
        self.assertEqual(path.count(f"{self.directory}/.local/bin"), 1)
        self.assertEqual(out[1], "yes")

    def test_env_file_trusts_mise_config_in_the_workspace(self):
        # Read it in a child shell: mise runs as a child of the agent, so the
        # value only counts when it is exported.
        out = self.source_env("sh -c 'printf %s \"$MISE_TRUSTED_CONFIG_PATHS\"'").stdout
        self.assertEqual(out, f"{self.directory}/workspace:/workspace")

    def test_shell_files_load_the_environment_once(self):
        # core-user.sh writes the lines; run its shell-file part against fakes.
        for tool in ("mise", "git"):
            self.fake(tool)
        (self.directory / ".oh-my-zsh/custom/plugins/zsh-autosuggestions").mkdir(parents=True)
        env_dir = self.directory / "etc-boxen"
        env_dir.mkdir()
        script = (GUEST / "core-user.sh").read_text().replace("source /etc/boxen/env.sh", f"source {GUEST / 'env.sh'}")
        (self.directory / "core-user.sh").write_text(script)
        for _ in range(2):
            result = subprocess.run(["bash", str(self.directory / "core-user.sh")], capture_output=True, text=True,
                                    env=dict(os.environ, HOME=str(self.directory), PATH=f"{self.bin}:{os.environ['PATH']}"))
            self.assertEqual(result.returncode, 0, result.stderr)
        for name in (".zshenv", ".bashrc", ".profile"):
            text = (self.directory / name).read_text()
            self.assertEqual(text.count("# boxen env"), 1, name)
            self.assertIn("/etc/boxen/env.sh", text)
        self.assertEqual((self.directory / ".zshrc").read_text().count("# boxen shell"), 1)
        self.assertIn("[sprite]", (self.directory / ".zshrc").read_text())

    def test_nothing_refers_to_the_sbx_world(self):
        for path in GUEST.iterdir():
            text = path.read_text()
            with self.subTest(script=path.name):
                for word in ("sandbox-persistent", "/home/agent", "SBX_", "proxy-managed", "_sudo"):
                    self.assertNotIn(word, text)


class Provisioning(ScriptCase):
    def test_base_packages_and_pinned_gh_and_mise(self):
        text = (GUEST / "core-root.sh").read_text()
        for package in ("zsh", "tmux", "jq", "ripgrep", "build-essential", "postgresql-client", "bubblewrap"):
            self.assertRegex(text, rf"\b{package}\b")
        self.assertEqual(len(re.findall(r"checksum=[0-9a-f]{64}\b", text)), 4)   # gh and mise, amd64 and arm64
        self.assertIn('chsh -s "$(command -v zsh)" "$1"', text)

    def test_pinned_downloads_are_checksummed(self):
        for script in GUEST.glob("*.sh"):
            text = script.read_text()
            with self.subTest(script=script.name):
                self.assertNotIn("@latest", text)
                self.assertNotIn("releases/latest", text)
                if re.findall(r'curl -fsSL "[^"]+" -o', text):
                    self.assertIn("sha256sum -c", text)

    def test_only_the_known_vendor_installers_are_piped_to_a_shell(self):
        piped = sorted(s.name for s in GUEST.glob("*.sh")
                       if re.search(r"curl [^|\n]*\|\s*(?:\w+=\S+\s+)*(?:ba)?sh\b", s.read_text()))
        self.assertEqual(piped, ["claude.sh", "cubic.sh", "grok.sh", "rtk-install.sh"])

    def test_gh_stack_is_one_pinned_release_with_its_skill_from_the_same_commit(self):
        script = (GUEST / "gh-stack.sh").read_text()
        self.assertIn("version=v0.2.1", script)
        self.assertEqual(len(re.findall(r"checksum=[0-9a-f]{64}\b", script)), 2)
        self.assertIn("ispinned: true", script)
        commits = set(re.findall(r"\b([0-9a-f]{40})\b", script))
        self.assertEqual(len(commits), 1)
        self.assertIn('fetch -q --depth 1 https://github.com/github/gh-stack.git "$commit"', script)
        self.assertIn('skills-install.sh "$src/skills" gh-stack', script)
        self.assertIn("export GH_STACK_NO_UPDATE_NOTIFIER=1", (GUEST / "env.sh").read_text())

    def test_nvchad_steps_are_time_limited_and_find_the_plugin_check(self):
        script = (GUEST / "nvchad.sh").read_text()
        for line in script.replace("\\\n", " ").splitlines():
            with self.subTest(line=line):
                self.assertNotRegex(line, r'^\s*(curl|nvim|npm|git clone) ')
        self.assertIn(GUEST_DIR + "lazy-check.lua", script)

    def test_docker_runs_dockerd_as_a_service_through_sudo(self):
        text = (GUEST / "docker-root.sh").read_text()
        self.assertIn("docker.io docker-compose-v2 docker-buildx", text)
        self.assertNotIn("sprite-env", text)
        # Fly's guide: overlay2, not Docker 29's containerd image store.
        self.assertIn('"storage-driver" = "overlay2"', text)
        self.assertIn('{"storage-driver": "overlay2"}', text)
        # sprite-env is not on root's sudo PATH: the service is created as the user.
        service = (GUEST / "docker-service.sh").read_text()
        self.assertIn('dockerd="$(PATH="$PATH:/usr/sbin"; command -v dockerd)"', service)
        self.assertIn('sprite-env services create dockerd --cmd /usr/bin/sudo --args "-n,$dockerd"', service)
        plugin = (ROOT / "plugins/docker.sh").read_text()
        self.assertIn("box_guest root docker-root.sh", plugin)
        self.assertIn("box_guest user docker-service.sh", plugin)
        self.assertIn('usermod -aG docker "$1"', text)

    def test_skills_install_links_every_skill_for_every_agent(self):
        source = Path(tempfile.mkdtemp(prefix="skills repo ", dir=self.directory))
        for name in ("botfight", "other"):
            (source / name).mkdir()
            (source / name / "SKILL.md").write_text(f"---\nname: {name}\n---\n")
        (source / "README.md").write_text("not a skill\n")
        for _ in range(2):
            self.run_script("skills-install.sh", str(source), "botfight")
        for target in (self.directory / ".claude/skills", self.directory / ".agents/skills"):
            self.assertEqual(sorted(p.name for p in target.iterdir()), ["botfight", "other"])
            self.assertTrue((target / "botfight/SKILL.md").is_file())
        # A required skill that is missing fails the install.
        self.assertNotEqual(self.run_script("skills-install.sh", str(source), "absent", ok=False).returncode, 0)

    def test_workspace_script_creates_links_and_preserves(self):
        root = self.directory / "fs"
        (root / "home/sprite").mkdir(parents=True)
        env = {"BOXEN_FS_ROOT": str(root)}
        self.run_script("workspace.sh", env=env)
        self.assertTrue((root / "home/sprite/workspace").is_dir())
        self.assertEqual(os.readlink(root / "workspace"), "/home/sprite/workspace")
        (root / "home/sprite/workspace/keep").write_text("x")
        self.run_script("workspace.sh", env=env)
        self.assertEqual((root / "home/sprite/workspace/keep").read_text(), "x")
        os.unlink(root / "workspace"); (root / "workspace").mkdir()
        self.run_script("workspace.sh", env=env)
        self.assertFalse(os.path.islink(root / "workspace"))

    def test_rtk_claude_hook_merges_without_touching_other_hooks(self):
        claude = self.directory / ".claude"; claude.mkdir()
        settings = claude / "settings.json"
        before = {"model": "opus", "hooks": {"PreToolUse": [
            {"matcher": "Bash", "hooks": [{"type": "command", "command": "audit"}, {"type": "command", "command": "rtk hook claude"}]}],
            "Stop": [{"hooks": [{"type": "command", "command": "notify"}]}]}}
        settings.write_text(json.dumps(before))
        self.run_script("rtk-claude-hook.sh"); self.run_script("rtk-claude-hook.sh")
        after = json.loads(settings.read_text())
        self.assertEqual(after["hooks"]["Stop"], before["hooks"]["Stop"])
        commands = [h["command"] for entry in after["hooks"]["PreToolUse"] for h in entry["hooks"]]
        self.assertEqual(commands.count("rtk hook claude"), 1)
        self.assertIn("audit", commands)

    def test_rtk_codex_hook_runs_rtk_init(self):
        self.fake("rtk", 'echo "rtk $*" >> "$HOME/calls"')
        self.run_script("rtk-codex-hook.sh")
        self.assertEqual((self.directory / "calls").read_text().strip(), "rtk init --global --codex")

    def test_gh_auth_points_git_at_gh(self):
        self.fake("git", 'echo "git $*" >> "$HOME/calls"')
        self.run_script("gh-auth.sh")
        calls = (self.directory / "calls").read_text()
        self.assertIn("credential.https://github.com.helper !gh auth git-credential", calls)


class ShellHelpers(ScriptCase):
    def gdiff(self, shell, *args):
        log = self.directory / "calls"
        self.fake("git", f'printf "git %s\\n" "$*" >> {log}; echo a.txt')
        # fzf records its preview command, which fzf would run through a shell.
        self.fake("fzf", f'while [ $# -gt 0 ]; do [ "$1" = --preview ] && printf "preview %s\\n" "$2" >> {log}; shift; done; cat >/dev/null')
        quoted = " ".join("'" + a.replace("'", "'\\''") + "'" for a in args)
        script = f'source {GUEST / "fzf-shell.sh"}; gdiff {quoted}'
        env = dict(os.environ, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}")
        result = subprocess.run([shell, "-c", script], env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        # git and fzf run side by side in a pipe, so either may log first.
        lines = sorted(log.read_text().splitlines())
        log.unlink()
        return lines

    def test_gdiff_puts_options_before_paths_and_previews_with_options_only(self):
        shells = ["bash"] + (["zsh"] if shutil.which("zsh") else [])
        for shell in shells:
            with self.subTest(shell=shell):
                self.assertEqual(self.gdiff(shell, "--cached", "--", "src dir"),
                                 ["git diff --name-only --cached -- src dir",
                                  "preview git diff --cached --color=always -- {}"])
                self.assertEqual(self.gdiff(shell, "main"),
                                 ["git diff --name-only main", "preview git diff main --color=always -- {}"])


class Agents(ScriptCase):
    def setUp(self):
        super().setUp()
        self.log = self.directory / "calls"
        for tool in ("claude", "codex", "grok", "zsh"):
            self.fake(tool, f'echo "{tool} $*" >> {self.log}\nexit "${{FAKE_EXIT:-0}}"')

    def run_agent(self, script, agent, *args, fake_exit=0):
        result = self.run_script(script, *args, ok=False, env={"BOXEN_AGENT": agent, "FAKE_EXIT": str(fake_exit)})
        calls = self.log.read_text().splitlines() if self.log.exists() else []
        self.log.unlink(missing_ok=True)
        return result, calls

    def test_status_asks_each_agent(self):
        for agent, calls in (("claude", ["claude auth status"]), ("codex", ["codex login status"])):
            result, got = self.run_agent("agent-login.sh", agent, "status")
            self.assertEqual((result.returncode, got, result.stdout), (0, calls, agent + "\n"))
            self.assertEqual(self.run_agent("agent-login.sh", agent, "status", fake_exit=1)[0].returncode, 10)
        for agent in ("shell", "grok"):
            self.assertEqual(self.run_agent("agent-login.sh", agent, "status")[0].returncode, 0)

    def test_codex_signs_in_by_device_and_claude_signs_itself_in(self):
        result, calls = self.run_agent("agent-login.sh", "codex", "login")
        self.assertEqual((result.returncode, calls), (0, ["codex login --device-auth"]))
        result, calls = self.run_agent("agent-login.sh", "claude", "login")
        self.assertEqual((result.returncode, calls), (1, []))
        self.assertIn("/login", result.stderr)

    def test_start_runs_the_chosen_agent_with_its_arguments(self):
        cases = {"claude": "claude --dangerously-skip-permissions -c",
                 "codex": "codex --dangerously-bypass-approvals-and-sandbox -c",
                 "grok": "grok --yolo --no-auto-update -c", "shell": "zsh -l -c"}
        for agent, expected in cases.items():
            result, calls = self.run_agent("agent-start.sh", agent, "-c")
            self.assertEqual((result.returncode, calls), (0, [expected]), agent)
        self.assertEqual(self.run_agent("agent-start.sh", "nope")[0].returncode, 64)

    def test_shell_mode_opens_zsh_whatever_the_agent(self):
        self.assertEqual(self.run_agent("agent-start.sh", "claude", "--shell")[1], ["zsh -l"])
        self.assertEqual(self.run_agent("agent-start.sh", "codex", "--shell", "ls -la 'a b'")[1], ["zsh -lc ls -la 'a b'"])

    def test_check_covers_only_the_chosen_plugins(self):
        text = (GUEST / "check.sh").read_text()
        for plugin in [l.split("\t")[0] for l in (ROOT / "plugins/plugins.tsv").read_text().splitlines()[1:]]:
            if plugin in ("supabase-serve", "just", "glow", "mermaid-ascii", "overmind"):
                continue
            self.assertIn(f"has {plugin}", text, plugin)
        self.assertIn("for tool in just glow mermaid-ascii overmind", text)
        result = self.run_script("check.sh", ok=False, env={"BOXEN_AGENT": "nope", "BOXEN_PLUGINS": ""})
        self.assertIn("FAIL agent nope", result.stdout)


class Secrets(unittest.TestCase):
    def test_no_identity_or_token_is_bundled(self):
        for folder in ("guest", "plugins", "policies", "lib"):
            for path in (ROOT / folder).rglob("*"):
                if path.is_file():
                    text = path.read_text(errors="ignore")
                    self.assertNotRegex(text, r"(tskey-auth-|github_pat_|ghp_|sk-ant-)[A-Za-z0-9]", path)
                    self.assertNotRegex(text, r"export (GH_TOKEN|OP_SERVICE_ACCOUNT_TOKEN)=[^%\s]", path)


if __name__ == "__main__":
    unittest.main()
