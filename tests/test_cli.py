"""Exercise host commands without a Docker account or an installed hypervisor."""
import base64
import io
import json
import os
import pty
import re
import select
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
KITS = "tailscale supabase-serve gh-auth 1pass rtkplus".split()
WORKLOAD = str(ROOT / "v3/boxen")


def mixin(agent):
    """The agent mixin the launcher composes, read from the pins the gates use."""
    out = subprocess.run(["bash", "-c", f'source lib/pins.sh && mixin_ref {agent}'], cwd=ROOT,
                         capture_output=True, text=True)
    return out.stdout.strip()


FAKE_SBX = """#!/usr/bin/env python3
import base64, json, os, sys
args = sys.argv[1:]
entry = {'args': args}
if '-i' in args or args[:2] == ['secret', 'set']:
    entry['stdin_b64'] = base64.b64encode(sys.stdin.buffer.read()).decode()
with open(os.environ['FAKE_SBX_LOG'], 'a') as f:
    f.write(json.dumps(entry) + '\\n')
state = os.environ['FAKE_SBX_STATE']
names = json.load(open(state)) if os.path.exists(state) else []
running = set(os.environ.get('FAKE_SBX_RUNNING', '').split(','))
def save():
    json.dump(names, open(state, 'w'))
if args[0] == 'ls':
    if '--quiet' in args:
        print('\\n'.join(names))
    elif '--json' in args:
        print(json.dumps({'sandboxes': [{'name': n, 'status': 'running' if n in running else 'stopped'} for n in names]}))
elif args[:2] == ['secret', 'ls']:
    service = args[args.index('--service') + 1]
    have = service in os.environ.get('FAKE_GLOBAL_SECRETS', '').split(',')
    print(json.dumps({'secrets': [{'service': service, 'scope': 'global'}] if have else []}, indent=2))
elif args[0] == 'exec' and any('agent-login.sh' in a for a in args) and args[-1] == 'status':
    sys.exit(int(os.environ.get('FAKE_LOGIN_STATUS', '0')))
elif args[0] == 'version':
    print('sbx version: v' + os.environ.get('FAKE_SBX_VERSION', '0.47.0') + ' 0411f50')
elif args[0] == 'create':
    if os.environ.get('FAKE_CREATE_FAIL'):
        sys.exit(7)
    names.append(args[args.index('--name') + 1]); save()
elif args[0] == 'run' and '--detached' in args and os.environ.get('FAKE_RUN_FAIL'):
    sys.exit(3)
elif args[0] == 'rm' and not os.environ.get('FAKE_RM_DECLINE'):
    names.remove(args[1]); save()
elif args[:2] == ['kit', 'validate'] and args[2].endswith('/1pass'):
    sys.exit(1)
"""

# sbx builds local kits with Docker; the launcher only asks whether it is there.
FAKE_DOCKER = """#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['FAKE_DOCKER_LOG'], 'a') as f:
    f.write(json.dumps({'args': args}) + '\\n')
if os.environ.get('FAKE_DOCKER_FAIL'):
    sys.exit(1)
sys.exit(0 if args[:1] == ['info'] or args[:2] == ['buildx', 'version'] else 2)
"""


class CLI(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="boxen-test-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.log = self.directory / "calls.jsonl"
        self.state = self.directory / "sandboxes.json"
        self.fake = self.directory / "bin" / "sbx"
        self.fake.parent.mkdir()
        self.fake.write_text(FAKE_SBX)
        self.fake.chmod(0o755)
        self.docker = self.directory / "bin" / "docker"
        self.docker.write_text(FAKE_DOCKER)
        self.docker.chmod(0o755)
        self.docker_log = self.directory / "docker.jsonl"
        self.project = self.directory / "project"
        self.project.mkdir()
        self.env = dict(
            os.environ, SBX_BIN=str(self.fake), FAKE_SBX_LOG=str(self.log),
            FAKE_SBX_STATE=str(self.state), BOXEN_STATE_DIR=str(self.directory / "state"),
            BOXEN_SKIP_MEMORY_CHECK="1", DOCKER_BIN=str(self.docker), FAKE_DOCKER_LOG=str(self.docker_log),
            BOXEN_SKIP_KVM_CHECK="1",
        )
        # Prevent real global Git identity/configuration from affecting tests.
        self.env["GIT_CONFIG_GLOBAL"] = str(self.directory / "gitconfig")
        self.env["GIT_CONFIG_NOSYSTEM"] = "1"

    def sandboxes(self, *names):
        self.state.write_text(json.dumps(list(names)))

    def cli(self, *args, stdin="", ok=True, cwd=None, launcher=None):
        result = subprocess.run(
            [os.environ.get("TEST_BASH", "bash"), str(launcher or ROOT / "boxen"), *args],
            env=self.env, input=stdin, text=True, capture_output=True, timeout=20,
            cwd=cwd or self.project,
        )
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def calls(self, everything=False):
        if not self.log.exists():
            return []
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        return calls if everything else [c for c in calls if c["args"][0] not in ("ls", "version")
                                         and c["args"][:2] != ["secret", "ls"]]

    def kits(self, args):
        """Boxen's own kits, in order. The agent mixin is a registry reference."""
        return [Path(args[i + 1]).name for i, a in enumerate(args)
                if a == "--kit" and args[i + 1].startswith(str(ROOT / "v3"))]

    def agent_mixins(self, args):
        return [args[i + 1] for i, a in enumerate(args) if a == "--kit" and not args[i + 1].startswith(str(ROOT))]

    # --- create ---------------------------------------------------------------

    def test_no_copy_is_mountless_and_links_the_workspace(self):
        self.cli("create", "scratch", "--no-copy", "--plugins", "none")
        calls = self.calls()
        self.assertEqual(calls[0]["args"][-1], WORKLOAD)
        self.assertIn("BOXEN_PLUGINS=", calls[0]["args"])
        self.assertEqual(self.kits(calls[0]["args"]), ["workspace"])
        self.assertEqual(self.agent_mixins(calls[0]["args"]), [])
        self.assertEqual(calls[1]["args"], ["run", "--detached", "--name", "scratch"])
        self.assertFalse(any("tar" in c["args"] for c in calls))

    def test_default_copies_the_current_directory(self):
        (self.project / "file").write_text("x")
        self.cli("create", "box", "--plugins", "none")
        calls = self.calls()
        self.assertNotIn(str(self.project), calls[0]["args"])
        self.assertIn("workspace", self.kits(calls[0]["args"]))
        # The workspace mixin's install hook made the directory; no root exec prepares it.
        self.assertFalse(any("--user" in c["args"] for c in calls))
        copy = next(c for c in calls if "stdin_b64" in c and "tar" in c["args"])
        archive = tarfile.open(fileobj=io.BytesIO(base64.b64decode(copy["stdin_b64"])))
        self.assertEqual(archive.extractfile("./file").read(), b"x")

    def test_refuses_to_copy_home_or_root(self):
        home = self.directory / "home"
        home.mkdir()
        self.env["HOME"] = str(home)
        self.cli("create", "box", cwd=home, ok=False)
        self.cli("create", "box", "-p", "/", ok=False)
        self.assertEqual(self.calls(), [])

    def test_default_plugins_and_resources(self):
        self.cli("create", "box", "--no-copy")
        args = self.calls()[0]["args"]
        self.assertEqual(self.kits(args), ["workspace"])
        self.assertIn("BOXEN_PLUGINS=", args)
        self.assertEqual(args[args.index("--memory") + 1], "4g")
        self.assertLessEqual(int(args[args.index("--cpus") + 1]), 4)

    def test_full_preset_is_ordered_and_has_no_chadmux(self):
        self.cli("create", "full", "--no-copy", "--plugins", "all", "--claude")
        args = self.calls()[0]["args"]
        self.assertEqual(self.agent_mixins(args), [mixin("claude")])
        self.assertEqual(self.kits(args), ["workspace", "tailscale", "gh-auth", "1pass", "rtkplus-claude"])
        self.assertIn("BOXEN_SERVE_PRESET=supabase", args)
        self.assertNotIn("chadmux", " ".join(args))
        self.assertEqual(args[args.index("--skills") + 1], "off")

    def test_dependency_added_and_duplicate_selection_deduplicated(self):
        self.cli("create", "routes", "--no-copy", "--plugins", "supabase-serve,supabase-serve")
        args = self.calls()[0]["args"]
        self.assertEqual(self.kits(args).count("tailscale"), 1)
        self.assertNotIn("supabase-serve", self.kits(args))

    def test_plugin_flags_add_to_the_defaults(self):
        self.cli("create", "box", "--no-copy", "--tailscale", "--gh-token", "--1pass", "--claude", "--no-tui")
        args = self.calls()[0]["args"]
        self.assertEqual(self.kits(args), ["workspace", "tailscale", "gh-auth", "1pass"])
        self.assertEqual(self.agent_mixins(args), [mixin("claude")])
        self.assertEqual(args[-1], WORKLOAD)

    def test_docker_is_always_included_not_chosen(self):
        self.cli("create", "box", "--no-copy", "--docker", "--plugins", "docker,gh-auth")
        args = self.calls()[0]["args"]
        self.assertEqual(self.kits(args), ["workspace", "gh-auth"])
        self.assertIn("BOXEN_PLUGINS=gh-auth", args)
        self.assertNotIn("docker", self.cli("plugins").stdout)

    def test_one_agent_per_sandbox(self):
        self.cli("create", "box", "--no-copy", "--agent", "claude", "--agent", "codex", ok=False)
        self.cli("create", "box", "--no-copy", "--claude", "--codex", ok=False)
        self.assertEqual(self.calls(), [])
        self.cli("create", "box", "--no-copy", "--claude", "--agent", "claude")

    def test_copy_does_not_mount_and_preserves_path_as_one_argument(self):
        project = self.directory / "my project; literal"
        project.mkdir()
        (project / "bytes").write_bytes(bytes(range(256)))
        (project / ".hidden").write_text("preserved")
        self.cli("create", "copy", str(project), "--plugins", "none")
        calls = self.calls()
        self.assertNotIn(str(project), calls[0]["args"])
        self.assertEqual(calls[2]["args"], ["exec", "-i", "--workdir", "/home/agent/workspace", "copy", "tar", "--no-same-owner", "--warning=no-unknown-keyword", "-xf", "-"])
        archive = tarfile.open(fileobj=io.BytesIO(base64.b64decode(calls[2]["stdin_b64"])))
        self.assertEqual(archive.extractfile("./bytes").read(), bytes(range(256)))
        self.assertEqual(archive.extractfile("./.hidden").read(), b"preserved")
        self.assertFalse(any(c["args"][0] in ("rm", "prune") for c in calls))

    def make_tree(self, files):
        for name in files:
            path = self.project / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)

    def copied(self, *args):
        result = self.cli("create", "box", "--plugins", "none", *args)
        stream = next(c for c in self.calls() if "tar" in c["args"])["stdin_b64"]
        names = tarfile.open(fileobj=io.BytesIO(base64.b64decode(stream))).getnames()
        return result.stdout, {n[2:] for n in names if n != "."}

    def test_copy_skips_folders_the_sandbox_rebuilds(self):
        self.make_tree([
            "mix.exs", "lib/app.ex", "deps/phoenix/mix.exs", "_build/dev/app.beam",
            "assets/package.json", "assets/node_modules/esbuild/bin", ".git/HEAD",
            "tools/deps/notes.txt", "py/.venv/pyvenv.cfg", "py/.venv/lib/x.py", "py/app.py",
            "web/.next/cache.json", "src/__pycache__/m.pyc", "app/[slug]/node_modules/x/i.js",
        ])
        stdout, names = self.copied()
        for kept in ("mix.exs", "lib/app.ex", "assets/package.json", ".git/HEAD", "tools/deps/notes.txt", "py/app.py"):
            self.assertIn(kept, names)
        for skipped in ("deps", "_build", "assets/node_modules", "py/.venv", "web/.next", "src/__pycache__",
                        "app/[slug]/node_modules"):
            self.assertFalse(any(n == skipped or n.startswith(skipped + "/") for n in names), skipped)
            self.assertIn("  " + skipped + "\n", stdout)
        self.assertIn("Copy: about", stdout)

    def test_copy_all_keeps_everything(self):
        self.make_tree(["mix.exs", "deps/phoenix/mix.exs", "assets/node_modules/esbuild/bin"])
        stdout, names = self.copied("--copy-all")
        self.assertIn("deps/phoenix/mix.exs", names)
        self.assertIn("assets/node_modules/esbuild/bin", names)
        self.assertNotIn("Skipping", stdout)

    def test_dry_run_shows_the_copy_plan(self):
        self.make_tree(["mix.exs", "deps/phoenix/mix.exs"])
        stdout = self.cli("create", "box", "--dry-run").stdout
        self.assertIn("Copy: about", stdout)
        self.assertIn("  deps\n", stdout)
        self.assertEqual(self.calls(everything=True), [])

    def test_explicit_mount_has_no_workspace_link(self):
        self.cli("create", "mount", str(self.project), "--mode", "mount", "--plugins", "none")
        args = self.calls()[0]["args"]
        self.assertEqual(args[-2:], [WORKLOAD, str(self.project)])
        self.assertEqual(self.kits(args), [])
        self.assertFalse(any("tar" in c["args"] for c in self.calls()))

    def test_clone_requires_git_before_any_sbx_mutation(self):
        self.cli("create", "clone", "--mode", "clone", ok=False)
        self.assertEqual(self.calls(), [])

    def test_agents_are_pinned_mixins_on_the_boxen_workload(self):
        for agent in ("claude", "codex", "grok"):
            with self.subTest(agent=agent):
                self.cli("create", f"{agent}-test", "--no-copy", "--agent", agent, "--plugins", "none")
                args = self.calls()[0]["args"]
                self.log.unlink()
                self.assertEqual(args[-1], WORKLOAD)
                self.assertEqual(self.agent_mixins(args), [mixin(agent)])
                self.assertRegex(mixin(agent), rf"^docker\.io/docker/sbx-kit-{agent}-mixin:[0-9][A-Za-z0-9.-]*$")
                # The agent mixin comes first, so Boxen's hooks run after its settings seed.
                self.assertLess(args.index(mixin(agent)), args.index(f"{ROOT}/v3/workspace"))
        self.cli("create", "shell-test", "--no-copy", "--plugins", "none")
        self.assertEqual(self.agent_mixins(self.calls()[0]["args"]), [])

    def test_launcher_shares_the_pins_with_the_gates(self):
        self.assertNotIn("sbx-kit-", (ROOT / "lib/cli.sh").read_text())
        self.assertIn('source "$PROJECT_DIR/lib/pins.sh"', (ROOT / "boxen").read_text())

    def test_rtk_mixin_follows_the_agent(self):
        self.cli("create", "rtk-claude", "--no-copy", "--claude", "--plugins", "rtkplus")
        self.assertIn("rtkplus-claude", self.kits(self.calls()[0]["args"])); self.log.unlink()
        self.cli("create", "rtk-codex", "--no-copy", "--codex", "--plugins", "rtkplus")
        self.assertIn("rtkplus-codex", self.kits(self.calls()[0]["args"])); self.log.unlink()
        result = self.cli("create", "rtk-shell", "--no-copy", "--plugins", "rtkplus")
        args = self.calls()[0]["args"]
        self.assertFalse([k for k in self.kits(args) if k.startswith("rtkplus")])
        self.assertIn("BOXEN_PLUGINS=", args)
        self.assertNotIn("BOXEN_PLUGINS=rtkplus", args)
        self.assertIn("RTK hooks apply to Claude and Codex", result.stdout + result.stderr)

    def test_supabase_serve_is_an_env_var_on_tailscale(self):
        self.cli("create", "routes", "--no-copy", "--plugins", "supabase-serve")
        args = self.calls()[0]["args"]
        self.assertEqual(self.kits(args), ["workspace", "tailscale"])
        self.assertIn("BOXEN_SERVE_PRESET=supabase", args)
        self.log.unlink()
        self.cli("create", "plain", "--no-copy", "--plugins", "tailscale")
        self.assertNotIn("BOXEN_SERVE_PRESET=supabase", self.calls()[0]["args"])

    def test_open_network_is_a_single_double_star_argument(self):
        self.cli("create", "wide", "--no-copy", "--plugins", "none", "--open-network")
        args = self.calls()[0]["args"]
        self.assertEqual(args[args.index("--allow-network") + 1], "**")
        self.log.unlink()
        self.cli("create", "narrow", "--no-copy", "--plugins", "none")
        self.assertNotIn("--allow-network", self.calls()[0]["args"])
        out = self.cli("create", "dry", "--no-copy", "--plugins", "none", "--open-network", "--dry-run").stdout
        self.assertIn("--allow-network '**'", out)

    def test_create_requires_a_docker_builder(self):
        self.env["FAKE_DOCKER_FAIL"] = "1"
        result = self.cli("create", "box", "--no-copy", "--plugins", "none", ok=False)
        self.assertIn("Install Docker and start it; sbx builds local v3 kits with it", result.stderr)
        self.assertEqual(self.calls(), [])
        self.cli("create", "box", "--no-copy", "--plugins", "none", "--dry-run")  # dry runs never need Docker

    def test_cubic_flag_is_gone(self):
        self.cli("create", "box", "--no-copy", "--cubic", ok=False)
        self.assertEqual(self.calls(), [])

    def test_old_sandboxes_keep_working(self):
        self.sandboxes("old")
        self.cli("check", "old")
        self.cli("old", "true")
        for call in self.calls():
            self.assertNotEqual(call["args"][0], "create")
        probe = next(c["args"] for c in self.calls() if "check.sh" in " ".join(c["args"]))
        self.assertIn("/usr/local/share/boxen/", " ".join(probe))
        self.assertIn("/home/agent/.local/share/boxen/", " ".join(probe))

    def test_doctor_reports_docker_and_has_a_cloud_path(self):
        self.assertIn("Docker builder: ok", self.cli("doctor").stdout)
        self.env.pop("BOXEN_SKIP_KVM_CHECK")
        self.assertIn("Docker builder: ok", self.cli("doctor", "--cloud").stdout)   # no KVM needed for cloud
        self.env["FAKE_DOCKER_FAIL"] = "1"
        result = self.cli("doctor", "--cloud", ok=False)
        self.assertIn("Docker builder: unavailable", result.stdout + result.stderr)

    def test_nothing_from_the_host_is_mounted_by_default(self):
        for agent in ("shell", "claude", "codex", "grok"):
            with self.subTest(agent=agent):
                self.cli("create", f"{agent}-box", "--agent", agent)
                args = [c for c in self.calls() if c["args"][0] == "create"][-1]["args"]
                self.assertEqual(args[args.index("--skills") + 1], "off")
                self.assertNotIn(str(self.project), args)
                self.assertNotIn("--clone", args)
        self.assertIn("Host mounts: none", self.cli("create", "preview", "--dry-run").stdout)

    def test_host_mounts_are_opt_in(self):
        self.cli("create", "skills", "--no-copy", "--skills", "readonly")
        args = self.calls()[0]["args"]
        self.assertEqual(args[args.index("--skills") + 1], "readonly")
        result = self.cli("create", "shared", "--mode", "mount", "--skills", "readwrite", "--dry-run")
        self.assertIn(f"Host mounts: {self.project.resolve()} (read-write); sbx skills store (readwrite)", result.stdout)
        self.cli("create", "bad", "--skills", "everything", ok=False)

    def tty(self, *args, script=()):
        """Run in a pseudo-terminal. script: (marker, input) pairs; each input is
        sent once its marker appears after the previous input."""
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(self.project)
            bash = os.environ.get("TEST_BASH", "bash")
            os.execvpe(bash, [bash, str(ROOT / "boxen"), *args], self.env)
        output = b""
        seen = 0

        def read_until(marker):
            nonlocal output
            while marker is None or marker not in output[seen:]:
                ready, _, _ = select.select([fd], [], [], 10)
                if not ready:
                    self.fail("Timed out waiting for %r: %s" % (marker, output.decode(errors="replace")))
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    return False
                if not chunk:
                    return False
                output += chunk
            return True

        for marker, data in script:
            if not read_until(marker):
                break
            seen = len(output)
            os.write(fd, data)
        read_until(None)
        os.close(fd)
        _, status = os.waitpid(pid, 0)
        return output.decode(errors="replace"), os.waitstatus_to_exitcode(status)

    def keys(self, keys):
        """Selector keystrokes, each sent after the selector redraws."""
        return [(b"always included", bytes([k])) for k in keys]

    def test_selector_chooses_an_agent_and_kits(self):
        # Rows: shell, claude, codex, grok, then kits from tailscale on.
        output, code = self.tty("create", "box", "--no-copy", "--dry-run", script=self.keys(b"j jjj \r"))
        self.assertEqual(code, 0, output)
        self.assertIn("Plugins: tailscale\r\n", output)
        self.assertIn("BOXEN_AGENT=claude", output)
        self.assertLess(output.index("Docker (Engine and Compose) and the core tools: always included"),
                        output.index("Agent (one per sandbox)"))

    def test_selector_quits_without_creating(self):
        output, code = self.tty("create", "box", "--no-copy", script=self.keys(b"q"))
        self.assertNotEqual(code, 0)
        self.assertIn("Aborted; nothing was created", output)
        self.assertEqual(self.calls(everything=True), [])

    def test_selector_is_skipped_when_plugins_are_chosen(self):
        for flag in ("--plugins", "--no-tui"):
            with self.subTest(flag=flag):
                args = ("--plugins", "none") if flag == "--plugins" else ("--no-tui",)
                output, code = self.tty("create", "box", "--no-copy", "--dry-run", *args)
                self.assertEqual(code, 0, output)
                self.assertNotIn("choose an agent", output)

    def test_plugin_keys_are_asked_for_and_stay_with_the_sandbox(self):
        self.env["FAKE_LOGIN_STATUS"] = "10"
        output, code = self.tty(
            "create", "box", "--no-copy", "--plugins", "gh-auth,1pass,tailscale", "--agent", "codex",
            script=[(b"GitHub token", b"github_pat_fake\r"), (b"1Password token", b"ops_fake'$(x)\r"),
                    (b"Tailscale auth key", b"tskey-auth-fake\r"), (b"Dev port", b"5173\r"),
                    (b"Sign in to your subscription now?", b"\r")])
        self.assertEqual(code, 0, output)
        calls = self.calls()
        github = next(c for c in calls if c["args"][:2] == ["secret", "set"])
        self.assertEqual(github["args"], ["secret", "set", "--sandbox", "box", "github"])
        self.assertEqual(base64.b64decode(github["stdin_b64"]).decode(), "github_pat_fake")
        op = next(c for c in calls if c["args"][-1] == "OP_SERVICE_ACCOUNT_TOKEN")
        line = base64.b64decode(op["stdin_b64"]).decode()
        self.assertEqual(subprocess.run(["bash", "-c", line + 'printf %s "$OP_SERVICE_ACCOUNT_TOKEN"'],
                                        capture_output=True, text=True).stdout, "ops_fake'$(x)")
        join = next(c for c in calls if "--auth-key-stdin" in c["args"])
        self.assertEqual(join["args"], ["exec", "-i", "--user", "root", "box", "/usr/local/bin/boxen-tailscale", "join", "box", "--auth-key-stdin"])
        self.assertEqual(base64.b64decode(join["stdin_b64"]).decode(), "tskey-auth-fake\n")
        self.assertIn(["exec", "--user", "root", "box", "/usr/local/bin/boxen-tailscale", "serve", "5173"], [c["args"] for c in calls])
        self.assertLoginCall(calls[-1]["args"], "box", "login")
        for secret in ("github_pat_fake", "ops_fake", "tskey-auth-fake"):
            self.assertNotIn(secret, json.dumps([c["args"] for c in calls]))
            self.assertNotIn(secret, output)

    def test_keys_are_asked_for_right_after_the_selector(self):
        # From the first row, k wraps to rtkplus, the last row; 1pass and gh-auth sit above it.
        output, code = self.tty(
            "create", "box", "--no-copy",
            script=self.keys(b"kk k ") + [(b"always included", b"\r"),
                                         (b"GitHub token", b"github_pat_fake\r"),
                                         (b"1Password token", b"ops_fake\r")])
        self.assertEqual(code, 0, output)
        self.assertLess(output.index("GitHub token"), output.index("1Password token"))
        self.assertLess(output.rindex("always included"), output.index("GitHub token"))
        github = next(c for c in self.calls() if c["args"][:2] == ["secret", "set"])
        self.assertEqual(base64.b64decode(github["stdin_b64"]).decode(), "github_pat_fake")
        self.assertTrue(any(c["args"][-1] == "OP_SERVICE_ACCOUNT_TOKEN" for c in self.calls()))

    def test_without_a_terminal_keys_are_left_for_later(self):
        result = self.cli("create", "box", "--no-copy", "--plugins", "gh-auth,1pass,tailscale")
        self.assertIn("boxen auth github box", result.stdout)
        self.assertIn("boxen env box OP_SERVICE_ACCOUNT_TOKEN", result.stdout)
        self.assertIn("boxen tailscale join box", result.stdout)
        self.assertFalse(any(c["args"][:2] == ["secret", "set"] or "--auth-key-stdin" in c["args"] for c in self.calls()))

    def test_sign_in_is_offered_on_the_way_in(self):
        self.sandboxes("box")
        self.env["FAKE_LOGIN_STATUS"] = "10"
        output, code = self.tty("box", script=[(b"Sign in to your subscription now?", b"n\r")])
        self.assertEqual(code, 0, output)
        self.tty("run", "box", script=[(b"Sign in to your subscription now?", b"\r")])
        calls = [c["args"] for c in self.calls()]
        self.assertEqual(len(calls), 5)
        self.assertLoginCall(calls[0], "box", "status")
        self.assertEqual(calls[1], ["exec", "-it", "box", "zsh", "-l"])
        self.assertLoginCall(calls[2], "box", "status")
        self.assertLoginCall(calls[3], "box", "login")
        self.assertEqual(calls[4], ["run", "--name", "box"])

    def assertLoginCall(self, args, name, action):
        """A guest-script exec: the sign-in probe tries the v3 path, then the pre-v3 one."""
        self.assertEqual(args[0], "exec")
        self.assertIn(name, args)
        self.assertEqual(args[-1], action)
        self.assertEqual(args[-2], "agent-login.sh")
        self.assertIn("/usr/local/share/boxen/", " ".join(args))
        self.assertIn("/home/agent/.local/share/boxen/", " ".join(args))
        if action == "login":
            self.assertIn("-it", args)
        else:
            self.assertNotIn("-it", args)

    def test_no_sign_in_offer_when_signed_in_or_running_a_command(self):
        self.sandboxes("box")
        output, code = self.tty("box")
        self.assertNotIn("Sign in", output)
        self.env["FAKE_LOGIN_STATUS"] = "10"
        self.tty("shell", "box", "ls")
        calls = [c["args"] for c in self.calls()]
        self.assertEqual(len(calls), 3)
        self.assertLoginCall(calls[0], "box", "status")
        self.assertEqual(calls[1], ["exec", "-it", "box", "zsh", "-l"])
        self.assertEqual(calls[2], ["exec", "-it", "box", "zsh", "-lc", "ls"])

    def test_host_wide_agent_secret_is_flagged(self):
        self.env["FAKE_GLOBAL_SECRETS"] = "anthropic"
        result = self.cli("create", "box", "--no-copy", "--agent", "claude")
        self.assertIn("host-wide anthropic secret", result.stderr)
        result = self.cli("create", "other", "--no-copy", "--agent", "codex")
        self.assertNotIn("host-wide", result.stderr)

    def test_resources_pass_through(self):
        self.cli("create", "box", "--no-copy", "--cpus", "2", "--memory", "1g")
        args = self.calls()[0]["args"]
        self.assertEqual(args[args.index("--cpus") + 1], "2")
        self.assertEqual(args[args.index("--memory") + 1], "1g")

    def test_memory_guard_stops_before_create(self):
        meminfo = self.directory / "meminfo"
        meminfo.write_text("MemTotal: 6000000 kB\nMemAvailable: 2097152 kB\n")
        self.env.update(BOXEN_MEMINFO=str(meminfo), BOXEN_SKIP_MEMORY_CHECK="0")
        result = self.cli("create", "box", "--no-copy", ok=False)
        self.assertIn("2048 MiB of memory is available", result.stderr)
        self.assertEqual(self.calls(), [])
        self.cli("create", "box", "--no-copy", "--memory", "512m")

    def test_failed_create_never_reuses_or_deletes_environment(self):
        self.env["FAKE_CREATE_FAIL"] = "1"
        self.cli("create", "existing", "--no-copy", ok=False)
        self.assertEqual(len(self.calls()), 1)

    def test_failure_after_create_explains_recovery(self):
        self.env["FAKE_RUN_FAIL"] = "1"
        result = self.cli("create", "half", "--no-copy", ok=False)
        self.assertIn("was created, but starting it failed", result.stderr)
        self.assertIn("sbx rm half", result.stderr)
        self.assertFalse(any(c["args"][0] == "rm" for c in self.calls()))

    def test_env_files_need_acknowledgement(self):
        (self.project / ".env").write_text("SECRET=1")
        (self.project / ".env.example").write_text("SECRET=")
        result = self.cli("create", "box", ok=False)
        self.assertIn(".env", result.stderr)
        self.assertNotIn(".env.example", result.stderr)
        self.assertEqual(self.calls(), [])
        self.cli("create", "box", "--dry-run")
        self.assertEqual(self.calls(), [])
        self.cli("create", "box", "--ack-env")

    def test_invalid_inputs_fail_before_sbx(self):
        for args in [
            ("create", "default"),
            ("create", "bad name"),
            ("create", "dotted.name"),
            ("create", "valid", "--plugins", "chadmux"),
            ("create", "valid", "--plugins", "typo"),
            ("create", "valid", "--plugins", "codex"),
            ("create", "valid", "--agent"),
            ("create", "valid", "--workspace", "/src"),
            ("create", "valid", "--workspace", "copy"),
            ("create", "valid", "--from", "base"),
            ("create", "valid", "--unknown"),
            ("create", "valid", "--memory", "lots"),
        ]:
            with self.subTest(args=args):
                self.cli(*args, ok=False)
        self.assertEqual(self.calls(everything=True), [])

    def test_dry_run_does_not_require_sbx(self):
        self.env["SBX_BIN"] = "/missing/sbx"
        result = self.cli("create", "preview", "--no-copy", "--dry-run")
        self.assertIn("Workspace: none", result.stdout)
        self.assertEqual(self.calls(everything=True), [])

    def test_create_ends_with_how_to_get_in(self):
        lines = self.cli("create", "boxen-claude-1", "--no-copy", "--agent", "claude").stdout.rstrip().splitlines()
        self.assertEqual(lines[-4:], ["To open a shell in the sandbox, run:", "  » boxen boxen-claude-1",
                                      "Start the agent with: boxen run boxen-claude-1",
                                      "Check the plugins with: boxen check boxen-claude-1"])
        self.assertNotIn("boxen run", self.cli("create", "plain", "--no-copy").stdout)

    def test_create_registers_the_sandbox(self):
        self.cli("create", "box", "--no-copy")
        self.assertEqual((self.directory / "state/sandboxes").read_text(), "box\n")

    # --- commands that take a name -------------------------------------------

    def test_mistyped_names_never_create(self):
        self.sandboxes("real")
        for args in [
            ("typo",), ("shell", "typo"), ("-s", "typo", "ls"), ("run", "typo"),
            ("exec", "typo", "true"), ("stop", "typo"), ("check", "typo"),
            ("net", "typo", "4000"), ("env", "typo", "FOO"), ("update", "typo"),
            ("delete", "typo"), ("auth", "github", "typo"), ("tailscale", "status", "typo"),
        ]:
            with self.subTest(args=args):
                result = self.cli(*args, stdin="value\n", ok=False)
                self.assertIn("Nothing was created", result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertEqual(json.loads(self.state.read_text()), ["real"])

    def test_run_forwards_agent_arguments(self):
        self.sandboxes("box")
        self.cli("run", "box", "--", "--version")
        self.cli("run", "box", "--version")
        self.cli("run", "box")
        self.assertEqual([c["args"] for c in self.calls()], [
            ["run", "--name", "box", "--", "--version"],
            ["run", "--name", "box", "--", "--version"],
            ["run", "--name", "box"],
        ])

    def test_shell_and_exec_preserve_arguments(self):
        self.sandboxes("box")
        self.cli("box")
        self.cli("shell", "box", "echo a | wc -c")
        self.cli("-s", "box", "printf", "%s", "$(no expansion)")
        self.cli("exec", "box", "printf", "%s", "$(no expansion)")
        calls = [c["args"] for c in self.calls()]
        self.assertEqual(calls[0], ["exec", "-i", "box", "zsh", "-l"])
        self.assertEqual(calls[1], ["exec", "-i", "box", "zsh", "-lc", "echo a | wc -c"])
        self.assertEqual(calls[2][:4], ["exec", "-i", "box", "zsh"])
        self.assertEqual(calls[2][-1], "printf %s \\$\\(no\\ expansion\\)")
        self.assertEqual(calls[3], ["exec", "-i", "box", "printf", "%s", "$(no expansion)"])

    def test_with_sudo_is_per_session(self):
        self.sandboxes("box")
        self.cli("shell", "--with-sudo", "box")
        self.assertEqual(self.calls()[0]["args"],
                         ["exec", "-i", "--user", "root", "box", "/usr/local/bin/boxen-sudo-session", "zsh", "-l"])

    def test_net_maps_ports_to_sbx_ports(self):
        self.sandboxes("box")
        self.cli("net", "box", "4000", "3000:8080")
        self.cli("-n", "box", "-b", "100.64.0.1", "4000")
        self.cli("net", "box", "-l")
        self.cli("net", "box", "-r", "4000")
        self.cli("net", "box", "-r", "all", ok=False)
        self.assertEqual([c["args"] for c in self.calls()], [
            ["ports", "box", "--publish", "127.0.0.1:4000:4000", "--publish", "127.0.0.1:3000:8080"],
            ["ports", "box", "--publish", "100.64.0.1:4000:4000"],
            ["ports", "box"],
            ["ports", "box", "--unpublish", "4000:4000"],
        ])

    def test_env_uses_the_proxy_for_known_services_and_stdin_for_others(self):
        self.sandboxes("box")
        secret = "sk-'quoted'-$(syntax)"
        self.cli("env", "box", "ANTHROPIC_API_KEY", stdin=secret + "\n")
        self.cli("-e", "box", "CUSTOM_TOKEN", stdin=secret + "\n")
        self.cli("env", "box", "1BAD", stdin="x\n", ok=False)
        calls = self.calls()
        self.assertEqual(calls[0]["args"], ["secret", "set", "--sandbox", "box", "anthropic"])
        self.assertEqual(base64.b64decode(calls[0]["stdin_b64"]).decode(), secret)
        self.assertEqual(calls[1]["args"][:5], ["exec", "-i", "box", "sh", "-c"])
        self.assertEqual(calls[1]["args"][-1], "CUSTOM_TOKEN")
        line = base64.b64decode(calls[1]["stdin_b64"]).decode()
        self.assertTrue(line.startswith("export CUSTOM_TOKEN="))
        self.assertEqual(subprocess.run(["bash", "-c", line + 'printf %s "$CUSTOM_TOKEN"'],
                                        capture_output=True, text=True).stdout, secret)
        for call in calls:
            self.assertNotIn(secret, json.dumps(call["args"]))

    def test_stop_delete_update(self):
        self.sandboxes("box")
        self.cli("-k", "box")
        self.cli("update", "box")
        self.env["FAKE_RM_DECLINE"] = "1"
        self.cli("delete", "box", ok=False)
        del self.env["FAKE_RM_DECLINE"]
        self.cli("-d", "box")
        calls = [c["args"] for c in self.calls()]
        self.assertEqual(calls[0], ["stop", "box"])
        self.assertEqual(calls[1][:6], ["exec", "--user", "root", "box", "sh", "-c"])
        self.assertIn("apt-get upgrade -y", calls[1][-1])
        self.assertEqual(calls[2:], [["rm", "box"], ["rm", "box"]])

    @unittest.skipUnless(shutil.which("jq"), "jq is not installed")
    def test_kill_all_stops_only_running_boxen_sandboxes(self):
        self.sandboxes("mine", "idle", "foreign")
        self.env["FAKE_SBX_RUNNING"] = "mine,foreign"
        state = self.directory / "state"
        state.mkdir()
        (state / "sandboxes").write_text("mine\nidle\ngone\n")
        self.cli("-ka")
        self.assertEqual([c["args"] for c in self.calls()], [["stop", "mine"]])

    # --- credentials -----------------------------------------------------------

    def test_auth_key_is_stdin_only(self):
        self.sandboxes("tailnet-test")
        secret = "test-secret-with-'quotes'-$dollars-and-$(syntax)\n"
        result = self.cli("tailscale", "join", "tailnet-test", "--auth-key-stdin", stdin=secret)
        call = self.calls()[0]
        self.assertEqual(base64.b64decode(call["stdin_b64"]).decode(), secret)
        self.assertNotIn(secret.strip(), json.dumps(call["args"]))
        self.assertNotIn(secret.strip(), result.stdout + result.stderr)
        self.assertEqual(call["args"][:4], ["exec", "-i", "--user", "root"])

    def test_tailscale_never_accepts_key_argument(self):
        self.sandboxes("scratch")
        self.cli("tailscale", "join", "scratch", "--auth-key", "sentinel", ok=False)
        self.assertEqual(self.calls(), [])

    def test_tailscale_status_runs_as_root(self):
        self.sandboxes("box")
        self.cli("tailscale", "status", "box")
        self.assertEqual(self.calls()[0]["args"], ["exec", "--user", "root", "box", "tailscale", "status"])

    def test_github_defaults_to_a_piped_fine_grained_token(self):
        self.sandboxes("box")
        self.cli("auth", "github", "box", stdin="github_pat_example")
        call = self.calls()[0]
        self.assertEqual(call["args"], ["secret", "set", "--sandbox", "box", "github"])
        self.assertEqual(base64.b64decode(call["stdin_b64"]).decode(), "github_pat_example")

    def test_secret_sources_are_host_references(self):
        self.sandboxes("scratch")
        # Fake host tools in a directory with a space; they must not execute here.
        tools = self.directory / "host tools"
        tools.mkdir()
        for binary in ("op", "gh"):
            tool = tools / binary
            tool.write_text("#!/bin/sh\nexit 99\n")
            tool.chmod(0o755)
        self.env["PATH"] = str(tools) + os.pathsep + self.env["PATH"]
        self.cli("auth", "github", "scratch", "--from-gh")
        self.cli("auth", "1password", "scratch", "github", "op://Work/GitHub/token")
        command = self.calls()[0]["args"]
        self.assertEqual(command[:6], ["secret", "set", "--sandbox", "scratch", "github", "--command"])
        self.assertEqual(command[6], str(tools / "gh").replace(" ", "\\ ") + " auth token")
        self.assertEqual(self.calls()[1]["args"][-2:], ["--ref", "op://Work/GitHub/token"])

    # --- host housekeeping -----------------------------------------------------

    def test_symlinked_launcher_finds_its_files(self):
        link = self.directory / "bin" / "boxen"
        link.symlink_to(ROOT / "boxen")
        self.assertIn("boxen create", self.cli("--help", launcher=link).stdout)

    def test_default_sbx_name_resolves_binary_without_recursion(self):
        self.env["SBX_BIN"] = "sbx"
        self.env["PATH"] = str(self.fake.parent) + os.pathsep + self.env["PATH"]
        self.cli("create", "scratch", "--no-copy", "--plugins", "none")
        self.assertEqual(self.calls()[0]["args"][0], "create")

    def test_doctor_rejects_old_sbx(self):
        self.env["FAKE_SBX_VERSION"] = "0.46.9"
        self.assertIn("too old", self.cli("doctor", ok=False).stderr)

    def test_validate_reports_every_kit(self):
        result = self.cli("validate", ok=False)
        validated = [c["args"][2] for c in self.calls() if c["args"][:2] == ["kit", "validate"]]
        self.assertEqual(sorted(Path(v).name for v in validated), sorted(p.name for p in (ROOT / "v3").iterdir()))
        self.assertIn("Some kits failed validation", result.stderr)

    def test_cron_keeps_path_and_replaces_its_own_line(self):
        crontab = self.directory / "crontab.txt"
        crontab.write_text("5 * * * * other-job\n")
        tool = self.directory / "bin" / "crontab"
        # Like real crontab, read all of stdin before replacing the table.
        tool.write_text(f"""#!/bin/sh
if [ "$1" = -l ]; then cat {crontab}; else new="$(cat)"; printf '%s\\n' "$new" > {crontab}; fi
""")
        tool.chmod(0o755)
        self.env["PATH"] = str(tool.parent) + os.pathsep + self.env["PATH"]
        self.cli("cron", "install", "3")
        self.cli("cron", "install", "4")
        lines = crontab.read_text().splitlines()
        self.assertEqual(lines[0], "5 * * * * other-job")
        self.assertEqual(len(lines), 2)
        self.assertTrue(lines[1].startswith("0 4 * * * PATH="))
        self.assertIn("update-all", lines[1])
        self.cli("cron", "remove")
        self.assertEqual(crontab.read_text().splitlines(), ["5 * * * * other-job"])
        self.cli("cron", "install", "24", ok=False)


if __name__ == "__main__":
    unittest.main()
