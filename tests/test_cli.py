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


FAKE_SBX = r"""#!/usr/bin/env python3
import base64, json, os, sys, time
argv = sys.argv[1:]
entry = {'args': argv}
cloud = argv[:1] == ['--cloud']
args = argv[1:] if cloud else argv
if '-i' in args or args[:2] == ['secret', 'set']:
    entry['stdin_b64'] = base64.b64encode(sys.stdin.buffer.read()).decode()
with open(os.environ['FAKE_SBX_LOG'], 'a') as f:
    f.write(json.dumps(entry) + '\n')
env = os.environ.get
state = env('FAKE_SBX_STATE')
def load(path, default):
    return json.load(open(path)) if os.path.exists(path) else default
def save(path, value):
    json.dump(value, open(path, 'w'))
# Local names are a list; the cloud also keeps creation times and TTL extensions.
cloud_path = state + '.cloud.json'
names = load(state, [])
db = load(cloud_path, {'names': []})
if isinstance(db, list):
    db = {'names': db}
db.setdefault('created', {}); db.setdefault('ext', {})
here = db['names'] if cloud else names
def save_names():
    save(cloud_path, db) if cloud else save(state, names)
secrets_path = state + '.secrets.json'
secrets = load(secrets_path, [s for s in env('FAKE_SECRETS', '').split(',') if s])
running = set(env('FAKE_SBX_CLOUD_RUNNING' if cloud else 'FAKE_SBX_RUNNING', '').split(','))
def fail(message, code=1):
    print(message, file=sys.stderr); sys.exit(code)
def flag(name):
    return args[args.index(name) + 1]
cmd = args[0]
if cmd == 'ls':
    if env('FAKE_LS_FAIL') == ('cloud' if cloud else 'local'):
        fail('cannot reach the sandbox service')
    if '--quiet' in args:
        print('\n'.join(here))
    elif '--json' in args:
        rows = [{'name': n, 'status': 'running' if n in running else 'stopped'} for n in here]
        for row in rows:
            if cloud:
                row['id'] = 'sbx_%s0001' % row['name']
        print(json.dumps({'sandboxes': rows}))
    else:
        print('\n'.join(['NAME'] + here))
elif args[:2] == ['secret', 'ls']:
    service = flag('--service')
    if '--global' in args:
        have = service in env('FAKE_GLOBAL_SECRETS', '').split(',')
    else:
        have = '%s:%s' % (flag('--sandbox'), service) in secrets
    print(json.dumps({'secrets': [{'service': service}] if have else []}, indent=2))
elif args[:2] == ['secret', 'set']:
    secrets.append('%s:%s' % (flag('--sandbox'), args[4])); save(secrets_path, secrets)
elif args[:2] == ['secret', 'rm']:
    pair = '%s:%s' % (flag('--sandbox'), args[4])
    if pair in secrets:
        secrets.remove(pair); save(secrets_path, secrets)
elif cmd == 'exec' and cloud and '--user' in args:
    fail('--user is not supported with --cloud', 2)
elif cmd == 'exec' and any('agent-login.sh' in a for a in args) and args[-1] == 'status':
    sys.exit(int(env('FAKE_LOGIN_STATUS', '0')))
elif cmd == 'version':
    print('sbx version: v' + env('FAKE_SBX_VERSION', '0.47.0') + ' 0411f50')
elif cmd == 'create':
    if cloud:
        fail('cloud create does not take local kits; use run', 9)
    if env('FAKE_CREATE_FAIL'):
        sys.exit(7)
    names.append(flag('--name')); save_names()
elif cmd == 'run' and '--detached' in args:
    name = flag('--name')
    if env('FAKE_RUN_FAIL'):
        # With FAKE_RUN_FAIL_AFTER_CREATE the sandbox exists before the run fails.
        if cloud and env('FAKE_RUN_FAIL_AFTER_CREATE') and name not in here:
            here.append(name); db['created'][name] = time.time(); save_names()
        sys.exit(3)
    if name not in here:
        here.append(name)
        if cloud:
            db['created'][name] = time.time()
        save_names()
elif cmd == 'rm' and not env('FAKE_RM_DECLINE'):
    here.remove(args[-1]); save_names()
elif args[:2] == ['setup', 'ssh']:
    os.makedirs(env('FAKE_SSH_STATE'), exist_ok=True)
    open(os.path.join(env('FAKE_SSH_STATE'), 'setup'), 'w').close()
elif cmd == 'ttl':
    # The period and Docker's ceiling count down from the sandbox's creation.
    name = args[-1]
    elapsed = int(time.time() - db['created'].get(name, time.time()))
    if args[1] == '--json':
        if env('FAKE_TTL_FAIL') == 'read':
            fail('ttl: cannot read the sandbox')
        left = int(env('FAKE_TTL_SECONDS', '28790')) - elapsed + db['ext'].get(name, 0)
        ceiling = int(env('FAKE_TTL_MAX', '86394')) - elapsed
        at = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() + left))
        print(json.dumps({'expires_in_seconds': left, 'max_remaining_seconds': ceiling, 'expires_at': at}))
    else:
        if env('FAKE_TTL_FAIL') == 'extend':
            fail('ttl: extension refused by the server')
        db['ext'][name] = db['ext'].get(name, 0) + int(args[1][1:-1]) * 60; save(cloud_path, db)
elif args[:2] == ['kit', 'validate'] and args[2].endswith('/1pass'):
    sys.exit(1)
"""

# A ControlMaster model: -M opens the master, -O check/forward/cancel/exit act
# on it, and -G reports sbx's proxy once sbx setup ssh has run.
FAKE_SSH = r"""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['FAKE_SSH_LOG'], 'a') as f:
    f.write(json.dumps({'args': args}) + '\n')
state = os.environ['FAKE_SSH_STATE']
os.makedirs(state, exist_ok=True)
master = os.path.join(state, 'master')
forwards = os.path.join(state, 'forwards')
if '-G' in args:
    if os.path.exists(os.path.join(state, 'setup')):
        print('proxycommand sbx cloud ssh-proxy %h %p')
    print('user agent')
    sys.exit(0)
if '-O' in args:
    verb = args[args.index('-O') + 1]
    if verb == 'check':
        sys.exit(0 if os.path.exists(master) else 255)
    if verb == 'exit':
        if os.path.exists(master):
            os.remove(master)
        sys.exit(0)
    if not os.path.exists(master):
        sys.exit(255)
    spec = args[args.index('-L') + 1]
    lines = open(forwards).read().split() if os.path.exists(forwards) else []
    if verb == 'forward':
        if spec.split(':')[1] in os.environ.get('FAKE_SSH_FORWARD_FAIL', '').split(','):
            print('mux_client_forward: forwarding request failed: Port forwarding failed', file=sys.stderr)
            sys.exit(1)
        lines.append(spec)
    elif verb == 'cancel' and spec in lines:
        lines.remove(spec)
    open(forwards, 'w').write(''.join(line + '\n' for line in lines))
    sys.exit(0)
if '-M' in args:
    open(master, 'w').close()
sys.exit(0)
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
        self.ssh = self.directory / "bin" / "ssh"
        self.ssh.write_text(FAKE_SSH)
        self.ssh.chmod(0o755)
        (self.directory / "ssh_config").write_text("")
        self.project = self.directory / "project"
        self.project.mkdir()
        self.env = dict(
            os.environ, SBX_BIN=str(self.fake), FAKE_SBX_LOG=str(self.log),
            FAKE_SBX_STATE=str(self.state), BOXEN_STATE_DIR=str(self.directory / "state"),
            BOXEN_SKIP_MEMORY_CHECK="1", DOCKER_BIN=str(self.docker), FAKE_DOCKER_LOG=str(self.docker_log),
            BOXEN_SKIP_KVM_CHECK="1", SSH_BIN=str(self.ssh), FAKE_SSH_LOG=str(self.directory / "ssh.jsonl"),
            FAKE_SSH_STATE=str(self.directory / "ssh-state"), SSH_CONFIG=str(self.directory / "ssh_config"),
            TMPDIR=str(self.directory),
        )
        for knob in ("BOXEN_CLOUD_TTL", "BOXEN_CPUS", "BOXEN_MEMORY"):
            self.env.pop(knob, None)
        # Prevent real global Git identity/configuration from affecting tests.
        self.env["GIT_CONFIG_GLOBAL"] = str(self.directory / "gitconfig")
        self.env["GIT_CONFIG_NOSYSTEM"] = "1"

    def sandboxes(self, *names):
        self.state.write_text(json.dumps(list(names)))

    def cloud(self, *names):
        Path(str(self.state) + ".cloud.json").write_text(json.dumps({"names": list(names)}))

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

        def plain(args):  # the same filter for either backend
            return args[1:] if args[:1] == ["--cloud"] else args
        return calls if everything else [c for c in calls if plain(c["args"])[0] not in ("ls", "version")
                                         and plain(c["args"])[:2] != ["secret", "ls"]]

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

    # --- cloud ----------------------------------------------------------------

    def test_cloud_create_sets_ttl_and_stop(self):
        self.cli("create", "team", "--no-copy", "--cloud", "--claude", "--plugins", "gh-auth")
        calls = self.calls()
        args = calls[0]["args"]
        self.assertEqual(args[:3], ["--cloud", "run", "--detached"])
        self.assertEqual(args[args.index("--ttl") + 1], "8h")
        self.assertEqual(args[args.index("--on-timeout") + 1], "stop")
        self.assertNotIn("--cpus", args); self.assertNotIn("--memory", args)
        self.assertEqual(self.kits(args), ["workspace", "gh-auth"])
        self.assertEqual(self.agent_mixins(args), [mixin("claude")])
        self.assertEqual(args[-1], WORKLOAD)
        self.assertFalse(any(c["args"][:2] == ["--cloud", "create"] for c in calls))

    def test_cloud_ttl_is_validated_and_stop_is_not_configurable(self):
        for i, (given, passed) in enumerate((("2", "2h"), ("2h", "2h"), ("5m", "5m"))):
            self.env["BOXEN_CLOUD_TTL"] = given
            self.cli("create", f"team{i}", "--no-copy", "--cloud", "--plugins", "none")
            args = self.calls()[0]["args"]
            self.assertEqual(args[args.index("--ttl") + 1], passed)
            self.assertEqual(args[args.index("--on-timeout") + 1], "stop")
            self.log.unlink()
        for bad in ("0", "25", "25h", "4m", "60m", "1.5", ""):
            self.env["BOXEN_CLOUD_TTL"] = bad
            result = self.cli("create", "team9", "--no-copy", "--cloud", "--plugins", "none", ok=False)
            self.assertIn("BOXEN_CLOUD_TTL must be hours from 1 to 24 (8 or 8h) or minutes from 5 to 59 (5m)", result.stderr)
        self.env["BOXEN_CLOUD_TTL"] = "8"
        self.cli("create", "team3", "--no-copy", "--cloud", "--on-timeout", "delete", ok=False)
        self.assertEqual(self.calls(), [])

    def test_cloud_resources_only_when_given_explicitly(self):
        self.env["BOXEN_CPUS"] = "4"; self.env["BOXEN_MEMORY"] = "4g"
        self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "none")
        self.assertNotIn("--cpus", self.calls()[0]["args"]); self.log.unlink()
        self.cli("create", "big", "--no-copy", "--cloud", "--plugins", "none", "--cpus", "4", "--memory", "8g")
        args = self.calls()[0]["args"]
        self.assertEqual((args[args.index("--cpus") + 1], args[args.index("--memory") + 1]), ("4", "8g"))

    def test_cloud_open_network_passes_through(self):
        self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "none", "--open-network")
        args = self.calls()[0]["args"]
        self.assertEqual(args[args.index("--allow-network") + 1], "**")

    def test_cloud_dry_run_prints_the_cloud_run(self):
        out = self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "none", "--dry-run").stdout
        self.assertIn(" --cloud run --detached --name team --ttl 8h --on-timeout stop ", out)
        self.assertEqual(self.calls(everything=True), [])

    def test_create_checks_the_selected_backend_only_and_before_any_mutation(self):
        self.env["FAKE_LS_FAIL"] = "cloud"                       # local create with no cloud access
        self.cli("create", "box", "--no-copy", "--plugins", "none")
        self.assertFalse(any(c["args"][0] == "--cloud" for c in self.calls(everything=True)))
        self.log.unlink()
        self.env["FAKE_LS_FAIL"] = "local"                       # cloud create with no local runtime
        self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "none")
        self.assertTrue(all(c["args"][0] == "--cloud" for c in self.calls(everything=True)))
        self.log.unlink(); del self.env["FAKE_LS_FAIL"]
        self.cloud("team", "team2")                              # an unregistered sandbox already on the selected backend
        result = self.cli("create", "team2", "--no-copy", "--cloud", "--gh-token-stdin", "--plugins", "gh-auth", stdin="ghp_fake\n", ok=False)
        self.assertIn("team2 already exists in the cloud (not made by boxen)", result.stderr)
        self.assertFalse(any({"secret", "run"} & set(c["args"]) for c in self.calls(everything=True)))
        self.log.unlink()
        self.env["FAKE_LS_FAIL"] = "cloud"                       # the selected backend cannot be listed
        result = self.cli("create", "team3", "--no-copy", "--cloud", "--plugins", "none", ok=False)
        self.assertIn("sbx ls failed", result.stderr)
        self.assertFalse(any("run" in c["args"] for c in self.calls(everything=True)))

    def test_create_never_replaces_a_secret_it_did_not_make(self):
        self.env["FAKE_SECRETS"] = "team:github"
        result = self.cli("create", "team", "--no-copy", "--cloud", "--gh-token-stdin", "--plugins", "gh-auth", stdin="ghp_fake\n", ok=False)
        self.assertIn("A GitHub secret already exists for team", result.stderr)
        self.assertFalse(any({"set", "run"} & set(c["args"]) for c in self.calls(everything=True)))
        self.log.unlink(); del self.env["FAKE_SECRETS"]
        self.env["FAKE_RUN_FAIL"] = "1"                          # the run fails before anything exists: our new secret goes
        self.cli("create", "team", "--no-copy", "--cloud", "--gh-token-stdin", "--plugins", "gh-auth", stdin="ghp_fake\n", ok=False)
        args = [c["args"] for c in self.calls(everything=True)]
        self.assertIn(["--cloud", "secret", "set", "--sandbox", "team", "github"], args)
        self.assertIn(["--cloud", "secret", "rm", "--sandbox", "team", "github"], args)
        self.assertFalse((self.directory / "state/sandboxes").exists())

    def test_create_keeps_a_sandbox_that_exists_after_a_failed_run_and_its_secret(self):
        self.env["FAKE_RUN_FAIL"] = "1"; self.env["FAKE_RUN_FAIL_AFTER_CREATE"] = "1"   # a timeout after remote creation
        result = self.cli("create", "team", "--no-copy", "--cloud", "--gh-token-stdin", "--plugins", "gh-auth", stdin="ghp_fake\n", ok=False)
        self.assertIn("team\tcloud", (self.directory / "state/sandboxes").read_text().splitlines())
        self.assertIn("boxen delete team", result.stderr)
        self.assertFalse(any(c["args"][1:3] == ["secret", "rm"] for c in self.calls(everything=True)))

    def test_gh_token_stdin_stores_the_secret_before_the_run_without_a_prompt(self):
        result = self.cli("create", "team", "--no-copy", "--cloud", "--gh-token-stdin", "--plugins", "none", stdin="ghp_fake\n")
        calls = self.calls(everything=True)
        args = [c["args"] for c in calls]
        stored = args.index(["--cloud", "secret", "set", "--sandbox", "team", "github"])
        self.assertEqual(base64.b64decode(calls[stored]["stdin_b64"]).decode(), "ghp_fake")
        run = next(i for i, a in enumerate(args) if a[:2] == ["--cloud", "run"])
        self.assertLess(stored, run)
        self.assertNotIn("GitHub token (blank to skip)", result.stdout)
        self.assertNotIn("ghp_fake", json.dumps(args) + result.stdout + result.stderr)
        self.assertIn("gh-auth", self.kits(args[run]))

    def test_create_reports_the_deadline_it_read_back_and_repairs_a_short_ttl(self):
        self.env["FAKE_TTL_SECONDS"] = "3599"; self.env["FAKE_TTL_MAX"] = "86000"   # the one-hour default after an exec (probe, 2026-10-22)
        result = self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "none")
        args = [c["args"] for c in self.calls(everything=True)]
        extend = next(a for a in args if a[:2] == ["--cloud", "ttl"] and a[2].startswith("+"))
        minutes = int(extend[2][1:-1])
        self.assertTrue(419 <= minutes <= 421, extend)                                 # ceil((28800 - elapsed - 3599) / 60)
        self.assertGreater(args.index(extend), args.index(["--cloud", "ttl", "--json", "team"]))
        self.assertIn(f"extended by {minutes} minutes", result.stdout)
        # Read back after the extension; which side of a second the read lands on decides 420 or 421.
        self.assertRegex(result.stdout, r"Stops at \S+ \(in (7h59m|8h0m); BOXEN_CLOUD_TTL asked for 8h\)")
        self.assertNotIn("longer period", result.stdout)

    def test_create_never_extends_past_the_ceiling_and_reports_a_longer_ttl(self):
        self.env["FAKE_TTL_SECONDS"] = "3599"; self.env["FAKE_TTL_MAX"] = "4000"; self.env["BOXEN_CLOUD_TTL"] = "24"
        self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "none")
        extend = next(c["args"] for c in self.calls(everything=True) if c["args"][:2] == ["--cloud", "ttl"] and c["args"][2].startswith("+"))
        self.assertEqual(extend[2], "+6m")                                              # floor((4000 - 3599) / 60), not the 22-hour shortfall
        self.log.unlink()
        self.env["FAKE_TTL_SECONDS"] = "3599"; self.env["FAKE_TTL_MAX"] = "86000"; self.env["BOXEN_CLOUD_TTL"] = "5m"
        result = self.cli("create", "team2", "--no-copy", "--cloud", "--plugins", "none")
        self.assertFalse(any(c["args"][:2] == ["--cloud", "ttl"] and c["args"][2].startswith("+") for c in self.calls(everything=True)))
        self.assertIn("Docker set a longer period than asked; it cannot be shortened", result.stdout)
        self.assertRegex(result.stdout, r"Stops at \S+ \(in 0h59m; BOXEN_CLOUD_TTL asked for 5m\)")

    def test_create_survives_a_failed_ttl_read_or_extension(self):
        self.env["FAKE_TTL_FAIL"] = "read"
        result = self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "none")
        self.assertIn("Could not read the TTL", result.stdout + result.stderr)
        self.assertIn("team\tcloud", (self.directory / "state/sandboxes").read_text().splitlines())
        self.log.unlink(); self.env["FAKE_TTL_FAIL"] = "extend"; self.env["FAKE_TTL_SECONDS"] = "3599"
        result = self.cli("create", "team2", "--no-copy", "--cloud", "--plugins", "none")
        self.assertIn("Could not extend the TTL", result.stdout + result.stderr)
        self.assertIn("extension refused by the server", result.stdout + result.stderr)
        self.assertRegex(result.stdout, r"Stops at \S+ \(in 0h59m")

    def test_cloud_refuses_what_needs_a_host(self):
        for flags in (["--mode", "mount"], ["--mode", "clone"], ["--skills", "readonly"]):
            with self.subTest(flags=flags):
                result = self.cli("create", "team", "--no-copy", "--cloud", *flags, ok=False)
                self.assertIn("cloud", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_cloud_boxes_keep_sudo_and_root_work_goes_through_it(self):
        self.cli("create", "team", "--no-copy", "--cloud", "--tailscale", "--plugins", "none")
        args = self.calls()[0]["args"]
        self.assertIn("BOXEN_CLOUD=1", args)
        self.assertIn("tailscale", self.kits(args)); self.log.unlink()
        self.cli("update", "team")
        update = self.calls()[-1]["args"]
        self.assertEqual(update[:4], ["--cloud", "exec", "team", "sudo"]); self.assertIn("-n", update)
        self.log.unlink()
        self.cli("tailscale", "status", "team")
        self.assertEqual(self.calls()[-1]["args"], ["--cloud", "exec", "team", "sudo", "-n", "tailscale", "status"])
        self.log.unlink()
        self.cli("tailscale", "join", "team", "--auth-key-stdin", stdin="tskey-auth-fake\n")
        join = self.calls()[-1]["args"]
        self.assertEqual(join, ["--cloud", "exec", "-i", "team", "sudo", "-n", "/usr/local/bin/boxen-tailscale", "join", "team", "--auth-key-stdin"])
        self.log.unlink()
        result = self.cli("shell", "--with-sudo", "team", "true")
        self.assertIn("sudo is already available", result.stdout + result.stderr)
        self.assertFalse(any("--user" in c["args"] for c in self.calls()))
        self.log.unlink()
        self.cli("create", "local", "--no-copy", "--plugins", "none")
        self.assertNotIn("BOXEN_CLOUD=1", self.calls()[0]["args"])

    def test_cloud_sandboxes_are_remembered_and_routed(self):
        self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "none")
        self.assertIn("team\tcloud", (self.directory / "state/sandboxes").read_text().splitlines())
        self.log.unlink()
        self.cli("shell", "team", "true"); self.cli("run", "team"); self.cli("stop", "team"); self.cli("check", "team")
        for call in self.calls(everything=True):
            self.assertEqual(call["args"][0], "--cloud", call)
        self.assertFalse(any("--user" in c["args"] for c in self.calls()))

    def test_a_stopped_cloud_box_resumes_on_the_way_in(self):
        self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "none"); self.log.unlink()
        self.cli("shell", "team", "true")
        self.assertEqual([c["args"][:3] for c in self.calls()][:2],
                         [["--cloud", "run", "--detached"], ["--cloud", "exec", "-i"]])
        self.log.unlink()
        self.env["FAKE_SBX_CLOUD_RUNNING"] = "team"
        self.cli("shell", "team", "true")
        self.assertFalse(any(c["args"][1] == "run" for c in self.calls()))

    def test_local_sandboxes_never_get_the_cloud_flag(self):
        self.cli("create", "box", "--no-copy", "--plugins", "none")
        self.log.unlink()
        self.cli("shell", "box", "true")
        self.assertFalse(any(c["args"][0] == "--cloud" for c in self.calls(everything=True)))

    def test_names_are_unique_across_backends_including_unregistered_ones(self):
        self.cli("create", "box", "--no-copy", "--plugins", "none")
        result = self.cli("create", "box", "--no-copy", "--cloud", "--plugins", "none", ok=False)
        self.assertIn("already names a local sandbox", result.stderr)
        self.cloud("stray")                       # exists in the cloud, never registered by this checkout
        result = self.cli("create", "stray", "--no-copy", "--cloud", "--plugins", "none", ok=False)
        self.assertIn("already exists in the cloud", result.stderr)
        self.sandboxes("box", "loose")            # exists locally, never registered
        result = self.cli("create", "loose", "--no-copy", "--plugins", "none", ok=False)
        self.assertIn("loose already exists locally (not made by boxen)", result.stderr)
        self.assertFalse(any(c["args"][1:3] == ["run", "--detached"] for c in self.calls()))

    def test_host_resolved_secrets_are_refused_on_cloud_before_any_call(self):
        self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "none"); self.log.unlink()
        for command in (["auth", "github", "team", "--from-gh"], ["auth", "1password", "team", "svc", "op://v/i/f"]):
            with self.subTest(command=command):
                result = self.cli(*command, ok=False)
                self.assertIn("not supported on cloud sandboxes", result.stderr)
        self.assertEqual(self.calls(), [])  # only the filtered `ls` existence checks ran

    def test_cloud_service_secrets_say_when_they_apply(self):
        self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "none"); self.log.unlink()
        result = self.cli("env", "team", "ANTHROPIC_API_KEY", stdin="sk-fake\n")
        self.assertEqual(self.calls()[0]["args"], ["--cloud", "secret", "set", "--sandbox", "team", "anthropic"])
        self.assertIn("Cloud secrets apply when the sandbox next starts", result.stdout)

    def test_bulk_commands_route_each_backend(self):
        self.cli("create", "local1", "--no-copy", "--plugins", "none")
        self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "none"); self.log.unlink()
        self.env["FAKE_SBX_RUNNING"] = "local1"; self.env["FAKE_SBX_CLOUD_RUNNING"] = "team"
        self.cli("kill-all")
        stops = [c["args"] for c in self.calls() if "stop" in c["args"]]
        self.assertIn(["stop", "local1"], stops); self.assertIn(["--cloud", "stop", "team"], stops)
        self.log.unlink()
        self.cli("update-all")
        updates = [c["args"] for c in self.calls() if "sh" in c["args"]]
        self.assertTrue(any(a[:2] == ["exec", "--user"] and "local1" in a for a in updates))
        self.assertTrue(any(a[:4] == ["--cloud", "exec", "team", "sudo"] for a in updates))
        self.log.unlink()
        self.assertIn("Cloud", self.cli("ls").stdout)

    def test_bulk_commands_skip_a_backend_that_cannot_be_listed(self):
        self.cli("create", "local1", "--no-copy", "--plugins", "none")
        self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "none"); self.log.unlink()
        self.env["FAKE_SBX_RUNNING"] = "local1"; self.env["FAKE_LS_FAIL"] = "cloud"
        result = self.cli("kill-all")
        self.assertIn(["stop", "local1"], [c["args"] for c in self.calls()])
        self.assertIn("Could not list the cloud sandboxes", result.stderr)

    def test_cloud_github_token_is_stored_before_the_run(self):
        output, code = self.tty("create", "team", "--no-copy", "--cloud", "--plugins", "gh-auth",
                                script=[(b"GitHub token", b"github_pat_fake\r")])
        self.assertEqual(code, 0, output)
        calls = self.calls()
        secret = next(i for i, c in enumerate(calls) if c["args"][1:3] == ["secret", "set"])
        run = next(i for i, c in enumerate(calls) if c["args"][1:3] == ["run", "--detached"])
        self.assertLess(secret, run)
        self.assertEqual(calls[secret]["args"], ["--cloud", "secret", "set", "--sandbox", "team", "github"])
        self.assertEqual(base64.b64decode(calls[secret]["stdin_b64"]).decode(), "github_pat_fake")
        self.assertNotIn("github_pat_fake", output)

    def test_cloud_failure_removes_only_what_it_stored(self):
        self.env["FAKE_RUN_FAIL"] = "1"
        output, code = self.tty("create", "team", "--no-copy", "--cloud", "--plugins", "gh-auth",
                                script=[(b"GitHub token", b"github_pat_fake\r")])
        self.assertNotEqual(code, 0)
        self.assertIn(["--cloud", "secret", "rm", "--sandbox", "team", "github"], [c["args"] for c in self.calls()])
        self.log.unlink()
        self.cli("create", "team2", "--no-copy", "--cloud", "--plugins", "gh-auth", ok=False)   # no terminal: no token stored
        self.assertFalse(any(c["args"][1:3] == ["secret", "rm"] for c in self.calls()))
        registry = self.directory / "state/sandboxes"
        self.assertFalse(registry.exists() and "team" in registry.read_text())

    def test_cloud_failure_after_creation_keeps_the_sandbox(self):
        # The run failed, but the sandbox exists in the cloud: remember it as cloud and say how to recover.
        self.env["FAKE_RUN_FAIL"] = "1"; self.env["FAKE_RUN_FAIL_AFTER_CREATE"] = "1"
        result = self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "none", ok=False)
        self.assertIn("team\tcloud", (self.directory / "state/sandboxes").read_text())
        self.assertIn("boxen delete team", result.stderr)
        self.assertFalse(any(c["args"][1:3] == ["secret", "rm"] for c in self.calls()))

    def test_without_a_terminal_cloud_keys_are_left_for_later(self):
        result = self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "gh-auth")
        self.assertIn("boxen auth github team", result.stdout)
        self.assertFalse(any(c["args"][1:3] == ["secret", "set"] for c in self.calls()))

    def test_cloud_create_warns_that_work_lives_in_the_sandbox(self):
        result = self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "none")
        self.assertIn("stops after 8 hours", result.stdout)
        self.assertIn("push often", result.stdout)
        self.assertIn("boxen net team PORT", result.stdout)

    # --- cloud previews over SSH ----------------------------------------------

    def ssh_calls(self):
        log = self.directory / "ssh.jsonl"
        return [json.loads(line)["args"] for line in log.read_text().splitlines()] if log.exists() else []

    def control(self, verb):
        return [a for a in self.ssh_calls() if "-O" in a and a[a.index("-O") + 1] == verb]

    def test_cloud_net_is_a_local_tunnel_never_a_public_port(self):
        self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "none"); self.log.unlink()
        self.cli("net", "team", "3000", "4000:5173")
        self.assertFalse(any("ports" in c["args"] for c in self.calls()))
        master = next(a for a in self.ssh_calls() if "-M" in a)
        self.assertEqual(master[-1], "sbx_team0001@sbx_cloud")
        self.assertIn("-N", master); self.assertIn("-f", master)
        self.assertEqual(master[:2], ["-F", str(self.directory / "ssh_config")])
        forwards = [a[a.index("-L") + 1] for a in self.control("forward")]
        self.assertEqual(forwards, ["127.0.0.1:3000:127.0.0.1:3000", "127.0.0.1:4000:127.0.0.1:5173"])
        socket_dir = Path(master[master.index("-S") + 1]).parent
        self.assertEqual(socket_dir.stat().st_mode & 0o777, 0o700)
        for flags in (["-b", "0.0.0.0", "3000"], ["-H", "example.com", "3000"]):
            self.assertIn("127.0.0.1 only", self.cli("net", "team", *flags, ok=False).stderr)
        self.assertIn("70000", self.cli("net", "team", "70000", ok=False).stderr)

    def test_cloud_net_runs_ssh_setup_once(self):
        self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "none"); self.log.unlink()
        self.cli("net", "team", "3000")
        self.assertEqual([c["args"] for c in self.calls() if "setup" in c["args"]], [["--cloud", "setup", "ssh"]])
        self.log.unlink()
        self.cli("net", "team", "3001")          # the fake's setup marker now exists: ssh -G reports the proxy
        self.assertFalse(any("setup" in c["args"] for c in self.calls()))

    def test_cloud_net_supabase_list_remove_and_partial_failure(self):
        self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "none"); self.log.unlink()
        self.cli("net", "team", "supabase")
        self.assertEqual([f.split(":")[1] for f in (a[a.index("-L") + 1] for a in self.control("forward"))],
                         ["3000", "3010", "3001", "54321", "54323", "54324", "8000"])
        listed = self.cli("net", "team", "-l").stdout
        for port in ("3000", "54321", "8000"):
            self.assertIn(f"127.0.0.1:{port}", listed)
        self.cli("net", "team", "-r", "54321")
        cancel = self.control("cancel")[-1]
        self.assertEqual(cancel[cancel.index("-L") + 1], "127.0.0.1:54321:127.0.0.1:54321")
        self.assertNotIn("54321", self.cli("net", "team", "-l").stdout)
        self.assertIn("already forwarded", self.cli("net", "team", "3000", ok=False).stderr)
        self.env["FAKE_SSH_FORWARD_FAIL"] = "54323"
        self.cli("net", "team", "-r", "3010"); self.cli("net", "team", "-r", "54323")
        result = self.cli("net", "team", "3010", "54323", ok=False)
        self.assertIn("54323", result.stderr)
        listed = self.cli("net", "team", "-l").stdout
        self.assertIn("127.0.0.1:3010", listed); self.assertNotIn("54323", listed)

    def test_dead_tunnels_are_reconciled(self):
        self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "none"); self.log.unlink()
        self.cli("net", "team", "3000")
        (self.directory / "ssh-state/master").unlink()      # the master died (sleep, expiry, external stop)
        self.assertIn("tunnel down", self.cli("net", "team", "-l").stdout)
        self.assertFalse(any("-M" in a for a in self.ssh_calls()[-1:]))   # listing never restarts it
        result = self.cli("net", "team", "3001")
        self.assertIn("127.0.0.1:3000", result.stdout + result.stderr)      # the dropped mapping is named
        self.assertEqual(len([a for a in self.ssh_calls() if "-M" in a]), 2)
        self.assertEqual([a[a.index("-L") + 1] for a in self.control("forward")][-1], "127.0.0.1:3001:127.0.0.1:3001")
        listed = self.cli("net", "team", "-l").stdout
        self.assertNotIn("127.0.0.1:3000", listed)          # the stale mapping was dropped, not advertised
        (self.directory / "ssh-state/master").unlink()
        self.cli("stop", "team"); self.cli("delete", "team", stdin="y\n")   # neither fails on a dead master

    def test_net_with_no_ports_reopens_the_recorded_forwards(self):
        self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "none"); self.log.unlink()
        self.cli("net", "team", "3000", "4000:5173")
        (self.directory / "ssh-state/master").unlink()
        self.cli("net", "team")
        self.assertEqual(len([a for a in self.ssh_calls() if "-M" in a]), 2)
        self.assertEqual([a[a.index("-L") + 1] for a in self.control("forward")][-2:],
                         ["127.0.0.1:3000:127.0.0.1:3000", "127.0.0.1:4000:127.0.0.1:5173"])
        listed = self.cli("net", "team", "-l").stdout
        self.assertIn("127.0.0.1:4000", listed); self.assertNotIn("tunnel down", listed)

    def test_stop_delete_and_kill_all_close_the_tunnel(self):
        self.cli("create", "team", "--no-copy", "--cloud", "--plugins", "none"); self.log.unlink()
        self.cli("net", "team", "3000")
        self.cli("stop", "team")
        self.assertEqual(self.control("exit")[-1][-1], "sbx_team0001@sbx_cloud")
        self.assertFalse((self.directory / "state/tunnels/team.forwards").exists())
        self.cli("net", "team", "3000")
        self.env["FAKE_SBX_CLOUD_RUNNING"] = "team"
        self.cli("kill-all")
        self.assertEqual(len(self.control("exit")), 2)

    def test_local_net_is_unchanged(self):
        self.cli("create", "box", "--no-copy", "--plugins", "none"); self.log.unlink()
        self.cli("net", "box", "3000")
        self.assertTrue(any("ports" in c["args"] and "--publish" in c["args"] for c in self.calls()))
        self.assertEqual(self.ssh_calls(), [])

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
