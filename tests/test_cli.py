"""Exercise bxn against a fake sprite CLI: no Fly account, no Sprite."""
import json
import os
import pty
import select
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FAKE = ROOT / "tests/fakes/sprite"
BASELINE = json.loads((ROOT / "policies/sprite-baseline.json").read_text())
DEFAULTS = [l.split("\t")[0] for l in (ROOT / "plugins/plugins.tsv").read_text().splitlines()[1:]
            if l.split("\t")[1] == "yes"]


class CLI(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="boxen-test-")
        self.addCleanup(temp.cleanup)
        self.directory = Path(temp.name)
        self.log = self.directory / "calls.jsonl"
        self.state = self.directory / "state"
        self.project = self.directory / "project"
        self.project.mkdir()
        self.config = self.directory / "config"
        self.config.mkdir()
        (self.config / "handle").write_text("me\n")
        self.env = dict(
            os.environ, SPRITE_BIN=str(FAKE), FAKE_SPRITE_LOG=str(self.log), FAKE_SPRITE_STATE=str(self.state),
            BOXEN_CONFIG_DIR=str(self.config), BOXEN_POLICY_WAIT="1", HOME=str(self.directory),
            # Keep the host's own Git identity and configuration out of the tests.
            GIT_CONFIG_GLOBAL=str(self.directory / "gitconfig"), GIT_CONFIG_NOSYSTEM="1",
        )
        self.env.pop("BOXEN_SPRITE_ORG", None)

    def sprites(self, *names):
        self.state.mkdir(exist_ok=True)
        (self.state / "names.json").write_text(json.dumps(list(names)))

    def cli(self, *args, stdin="", ok=True, cwd=None, launcher=None):
        result = subprocess.run(
            [os.environ.get("TEST_BASH", "bash"), str(launcher or ROOT / "bxn"), *args],
            env=self.env, input=stdin, text=True, capture_output=True, timeout=30, cwd=cwd or self.project,
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
        return calls if everything else [c for c in calls if c["args"][0] not in ("list", "org")]

    def execs(self):
        """The command each exec ran in the Sprite."""
        return [c["args"][c["args"].index("--") + 1:] for c in self.calls() if c["args"][0] == "exec"]

    def posted(self, kind):
        posts = [c for c in self.calls() if c["args"][0] == "api" and "POST" in c["args"]
                 and c["args"][3] == f"/policy/{kind}"]
        return json.loads(posts[-1]["stdin"]) if posts else None

    def create(self, *args, stdin="", ok=True):
        return self.cli("create", "web", "acme/web", "--no-tui", "--detach", *args, stdin=stdin, ok=ok)

    # --- create ---------------------------------------------------------------

    def test_create_locks_down_before_anything_else_touches_the_sprite(self):
        self.create()
        calls = self.calls()
        self.assertEqual(calls[0]["args"], ["create", "--skip-console", "--label", "boxen", "me-web"])
        kinds = [(c["args"][0], c["args"][3] if c["args"][0] == "api" else " ".join(c["args"][4:6])) for c in calls[1:]]
        # Both policies are posted, the network one read back inside, the profile from the API...
        self.assertEqual(kinds[:4], [("api", "/policy/network"), ("api", "/policy/privileges"),
                                     ("exec", "cat /.sprite/policy/network.json"), ("api", "/policy/privileges")])
        # ...and only then does anything run in the Sprite.
        self.assertEqual(self.execs()[1][:2], ["sudo", "-n"])
        self.assertIn("/etc/boxen/env.sh", " ".join(self.execs()[1]))

    def test_create_provisions_base_then_plugins_then_clones(self):
        self.create("--plugins", "just,gh-auth")
        names = [Path(w).name for e in self.execs() for w in e
                 if w.startswith("/usr/local/share/boxen/") and w.endswith(".sh")]
        self.assertEqual(names, ["core-root.sh", "core-user.sh", "workspace.sh", "gh-auth.sh", "just.sh"])
        clone = self.execs()[-1]
        self.assertEqual(clone[0:2], ["bash", "-c"])
        self.assertIn("git clone", clone[2])
        self.assertEqual(clone[-1], "https://github.com/acme/web.git")
        # The agent and plugins are recorded where the guest scripts read them.
        record = next(c for c in self.calls() if "/etc/boxen/sprite.env" in " ".join(c["args"]))
        self.assertEqual(record["stdin"], "export BOXEN_AGENT='shell'\nexport BOXEN_PLUGINS='gh-auth,just'\n")

    def test_network_policy_is_baseline_agent_plugins_and_extras(self):
        self.create("--agent", "claude", "--plugins", "1pass", "--allow", "Example.COM", "--allow", "*.corp.dev")
        rules = self.posted("network")["rules"]
        self.assertEqual(rules[:len(BASELINE["rules"])], BASELINE["rules"])
        domains = [r["domain"] for r in rules if "domain" in r]
        for host in ("api.anthropic.com", "claude.ai", "cache.agilebits.com", "*.1password.com", "example.com", "*.corp.dev"):
            self.assertIn(host, domains)
        self.assertEqual(len(domains), len(set(domains)))
        self.assertTrue(all(r.get("action") == "allow" for r in rules if "domain" in r))
        self.assertEqual(self.posted("privileges"), {"profile": "standard"})

    def test_docker_asks_for_privileged_and_supabase_serve_brings_docker(self):
        result = self.create("--plugins", "supabase-serve")
        self.assertEqual(self.posted("privileges"), {"profile": "privileged"})
        self.assertIn("[+] Installing docker\n[+] Installing supabase-serve", result.stdout)
        self.assertIn("deno.land", [r.get("domain") for r in self.posted("network")["rules"]])

    def test_a_sprite_that_does_not_enforce_the_policy_is_destroyed_untouched(self):
        self.env["FAKE_INSIDE_POLICY"] = '{"rules": []}'
        result = self.create(ok=False)
        self.assertIn("destroyed before anything was installed", result.stderr)
        self.assertIn(["destroy", "--force", "me-web"], [c["args"] for c in self.calls()])
        self.assertEqual([e for e in self.execs() if e[0] != "cat"], [])

    def test_a_failed_policy_post_also_destroys(self):
        self.env["FAKE_FAIL"] = "/policy/privileges"
        self.create(ok=False)
        self.assertIn(["destroy", "--force", "me-web"], [c["args"] for c in self.calls()])
        self.assertEqual(self.execs(), [])

    def test_allow_all_has_no_rules_and_says_so(self):
        result = self.create("--allow-all")
        self.assertEqual(self.posted("network"), {"rules": []})
        self.assertIn("no network policy and can reach any host", result.stderr)

    def test_dry_run_needs_no_sprite_cli_and_creates_nothing(self):
        self.env["SPRITE_BIN"] = str(self.directory / "missing")
        result = self.cli("create", "web", "acme/web", "--dry-run", "--no-tui", "--docker")
        self.assertIn("Sprite: me-web", result.stdout)
        self.assertIn("create --skip-console --label boxen me-web", result.stdout)
        self.assertIn("Plugins: " + ",".join(DEFAULTS + ["docker"]), result.stdout)
        self.assertIn("Privileges: privileged", result.stdout)
        self.assertIn("Network: defaults github.com", result.stdout)
        self.assertIn("Repository: https://github.com/acme/web.git", result.stdout)
        self.assertFalse(self.log.exists())

    def test_repositories_resolve_to_https(self):
        cases = {"acme/web": "https://github.com/acme/web.git",
                 "acme/web.git": "https://github.com/acme/web.git",
                 "https://gitlab.com/acme/web.git": "https://gitlab.com/acme/web.git",
                 "git@github.com:acme/web.git": "https://github.com/acme/web.git",
                 "ssh://git@github.com/acme/web": "https://github.com/acme/web.git"}
        for ref, url in cases.items():
            out = self.cli("create", "web", ref, "--dry-run", "--no-tui").stdout
            self.assertIn(f"Repository: {url}\n", out, ref)
        self.cli("create", "web", "file:///etc", "--dry-run", "--no-tui", ok=False)
        self.cli("create", "web", "git@gitlab.com:a/b.git", "--dry-run", "--no-tui", ok=False)

    def test_the_current_clone_is_the_default_repository(self):
        subprocess.run(["git", "init", "-q", str(self.project)], check=True, env=self.env)
        subprocess.run(["git", "-C", str(self.project), "remote", "add", "origin", "git@github.com:acme/app.git"],
                       check=True, env=self.env)
        self.assertIn("Repository: https://github.com/acme/app.git", self.cli("create", "app", "--dry-run", "--no-tui").stdout)
        self.assertIn("Repository: none", self.cli("create", "app", "--no-clone", "--dry-run", "--no-tui").stdout)
        self.cli("create", "app", "acme/x", "--no-clone", "--dry-run", "--no-tui", ok=False)
        result = self.cli("create", "app", "--dry-run", "--no-tui", ok=False, cwd=self.directory)
        self.assertIn("--no-clone", result.stderr)

    def test_github_token_from_stdin_reaches_the_env_file_and_no_argument(self):
        self.create("--gh-token-stdin", stdin="github_pat_secret\n")
        stored = next(c for c in self.calls() if c["args"][-1] == "GH_TOKEN")
        self.assertEqual(stored["stdin"], "export GH_TOKEN='github_pat_secret'\n")
        self.assertNotIn("github_pat_secret", json.dumps([c["args"] for c in self.calls()]))
        # Stored before the clone, which may need it.
        index = [c["args"] for c in self.calls()].index(stored["args"])
        self.assertTrue(any("git clone" in " ".join(c["args"]) for c in self.calls()[index:]))

    def test_without_a_terminal_keys_are_left_for_later(self):
        result = self.create("--plugins", "gh-auth,1pass", "--agent", "grok")
        self.assertIn("bxn auth github web", result.stdout)
        self.assertIn("bxn env web OP_SERVICE_ACCOUNT_TOKEN", result.stdout)
        self.assertIn("bxn env web XAI_API_KEY", result.stdout)

    def test_existing_names_and_failed_listings_stop_before_create(self):
        self.sprites("me-web")
        self.assertIn("already exists", self.create(ok=False).stderr)
        self.sprites()
        self.env["FAKE_NOT_LOGGED_IN"] = "1"
        self.assertIn("sprite login", self.create(ok=False).stderr)
        self.assertFalse(any(c["args"][0] == "create" for c in self.calls(everything=True)))

    def test_a_failed_create_mentions_the_org_limit(self):
        self.env.update(FAKE_CREATE_FAIL="1", FAKE_CREATE_STDERR="error: running sprite limit reached")
        result = self.create(ok=False)
        self.assertIn("running sprite limit reached", result.stderr)
        self.assertIn("$20 plan", result.stderr)
        self.assertIn("nothing was made", result.stderr)

    def test_a_failed_step_explains_recovery_without_destroying_unasked(self):
        self.env["FAKE_FAIL"] = "core-user.sh"
        result = self.create(ok=False)
        self.assertIn("me-web was created, but the shell setup failed", result.stderr)
        self.assertIn("bxn delete me-web", result.stderr)
        self.assertNotIn("destroy", [c["args"][0] for c in self.calls()])

    def test_a_failed_clone_is_a_warning_with_the_fix(self):
        self.env["FAKE_FAIL"] = "git clone"
        result = self.create()
        self.assertIn("bxn auth github web", result.stderr)
        self.assertIn("is ready", result.stdout)

    def test_git_identity_is_forwarded(self):
        (self.directory / "gitconfig").write_text("[user]\n\tname = Ada L\n\temail = ada@example.com\n")
        self.create()
        self.assertIn(["git", "config", "--global", "user.name", "Ada L"], self.execs())
        self.assertIn(["git", "config", "--global", "user.email", "ada@example.com"], self.execs())

    def test_plugins_flags_and_agents(self):
        out = self.cli("create", "web", "acme/web", "--dry-run", "--plugins", "none", "--nvchad", "--gh-token").stdout
        self.assertIn("Plugins: gh-auth,nvchad\n", out)
        out = self.cli("create", "web", "acme/web", "--dry-run", "--plugins", "all").stdout
        self.assertIn("rtkplus left out for shell", out)
        self.assertNotIn("rtkplus", out.split("Plugins: ")[1].splitlines()[0])
        out = self.cli("create", "web", "acme/web", "--dry-run", "--plugins", "rtkplus", "--codex").stdout
        self.assertIn("Plugins: rtkplus\n", out)
        for args, message in ((("--plugins", "nope"), "Unknown plugin"), (("--plugins", "claude"), "--agent"),
                              (("--claude", "--codex"), "One agent per Sprite"), (("--tailscale",), "Tailscale is gone"),
                              (("--agent", "cursor"), "Unknown agent"), (("--frobnicate",), "Unknown create option")):
            self.assertIn(message, self.cli("create", "web", "acme/web", "--dry-run", *args, ok=False).stderr, args)

    def test_agent_installs_are_checked_first(self):
        self.create("--codex", "--plugins", "none")
        joined = [" ".join(e) for e in self.execs()]
        check = next(i for i, e in enumerate(joined) if "command -v codex" in e)
        self.assertLess(check, next(i for i, e in enumerate(joined) if "git clone" in e))

    # --- names ----------------------------------------------------------------

    def test_the_handle_is_asked_once_and_prefixes_every_name(self):
        (self.config / "handle").unlink()
        self.env["USER"] = "Ada.Lovelace"
        result = self.cli("create", "web", "acme/web", "--dry-run", "--no-tui")
        self.assertIn("Sprite: ada-lovelace-web", result.stdout)
        self.assertEqual((self.config / "handle").read_text(), "ada-lovelace\n")
        self.cli("handle", "ada")
        self.assertEqual(self.cli("handle").stdout, "ada\n")
        self.cli("handle", "Not Valid", ok=False)
        (self.config / "handle").write_text("../x\n")
        self.cli("list", ok=False)

    def test_names_work_with_or_without_the_handle(self):
        self.sprites("me-web")
        self.cli("exec", "web", "true")
        self.cli("exec", "me-web", "true")
        self.assertEqual([c["args"][2] for c in self.calls()], ["me-web", "me-web"])

    def test_mistyped_names_never_create(self):
        for args in (("nope",), ("shell", "nope"), ("run", "nope"), ("exec", "nope", "ls"), ("allow", "nope", "a.com"),
                     ("env", "nope", "X"), ("delete", "nope", "--yes"), ("checkpoint", "nope"), ("proxy", "nope", "3000")):
            result = self.cli(*args, ok=False, stdin="value\n")
            self.assertIn("No Sprite named me-nope", result.stderr, args)
        self.assertEqual(self.calls(), [])

    # --- day to day -----------------------------------------------------------

    def test_shell_and_exec_preserve_arguments(self):
        self.sprites("me-web")
        self.cli("web")
        self.cli("shell", "web", "ls -la")
        self.cli("shell", "web", "printf", "%s\n", "a b")
        self.cli("exec", "web", "printf", "%s\n", "a b")
        start = ["bash", "/usr/local/share/boxen/agent-start.sh", "--shell"]
        execs = self.execs()
        self.assertEqual(execs[:2], [start, start + ["ls -la"]])
        self.assertEqual(execs[3], ["printf", "%s\n", "a b"])
        # Several arguments become one line that a shell splits back into them.
        self.assertEqual(execs[2][:3], start)
        words = subprocess.run(["bash", "-c", 'eval "set -- $1"; printf "%s\\0" "$@"', "_", execs[2][3]],
                               capture_output=True, text=True).stdout
        self.assertEqual(words.split("\0")[:-1], ["printf", "%s\n", "a b"])

    def test_run_forwards_agent_arguments(self):
        self.sprites("me-web")
        self.cli("run", "web", "--", "--resume", "two words")
        self.assertEqual(self.execs()[-1], ["bash", "/usr/local/share/boxen/agent-start.sh", "--resume", "two words"])

    def test_allow_reads_merges_and_posts_the_whole_policy(self):
        self.create("--plugins", "none")
        before = self.posted("network")
        self.cli("allow", "web", "API.example.org", "*.cdn.dev")
        after = self.posted("network")
        self.assertEqual(after["rules"][:len(before["rules"])], before["rules"])
        self.assertEqual(after["rules"][len(before["rules"]):],
                         [{"domain": "api.example.org", "action": "allow"}, {"domain": "*.cdn.dev", "action": "allow"}])
        self.cli("allow", "web", "not a host", ok=False)
        self.cli("allow", "web", "*", ok=False)

    def test_allow_on_an_unrestricted_sprite_says_so(self):
        self.create("--allow-all")
        self.assertIn("no network policy", self.cli("allow", "web", "a.com", ok=False).stderr)

    def test_policy_shows_both_policies(self):
        self.create("--plugins", "docker")
        out = self.cli("policy", "web").stdout
        self.assertIn('"include": "defaults"', out)
        self.assertIn("Privileges: privileged", out)

    def test_env_and_auth_take_values_on_stdin_only(self):
        self.sprites("me-web")
        self.cli("env", "web", "SOME_TOKEN", stdin="v4lue'$(x)\n")
        call = next(c for c in self.calls() if c["args"][-1] == "SOME_TOKEN")
        out = subprocess.run(["bash", "-c", call["stdin"] + 'printf %s "$SOME_TOKEN"'], capture_output=True, text=True)
        self.assertEqual(out.stdout, "v4lue'$(x)")
        self.cli("env", "web", "1BAD", stdin="x\n", ok=False)
        self.cli("env", "web", "EMPTY", stdin="", ok=False)
        self.cli("auth", "github", "web", stdin="github_pat_x\n")
        self.assertIn("export GH_TOKEN='github_pat_x'\n", [c.get("stdin") for c in self.calls()])
        self.assertIn(["bash", "/usr/local/share/boxen/gh-auth.sh"], self.execs())
        self.assertNotIn("v4lue", json.dumps([c["args"] for c in self.calls()]))
        self.assertNotIn("github_pat_x", json.dumps([c["args"] for c in self.calls()]))

    def test_delete_and_restore_confirm(self):
        self.sprites("me-web")
        self.assertIn("--yes", self.cli("delete", "web", ok=False).stderr)
        self.assertIn("--yes", self.cli("restore", "web", "v1", ok=False).stderr)
        self.cli("restore", "web", "v1", "--yes")
        self.assertIn(["restore", "-s", "me-web", "v1"], [c["args"] for c in self.calls()])
        self.cli("delete", "web", "--yes")
        self.assertIn(["destroy", "--force", "me-web"], [c["args"] for c in self.calls()])

    def test_checkpoints(self):
        self.sprites("me-web")
        self.cli("checkpoint", "web", "before upgrade")
        self.cli("checkpoint", "web")
        self.cli("checkpoints", "web")
        self.assertEqual([c["args"] for c in self.calls()], [
            ["checkpoint", "create", "-s", "me-web", "--comment", "before upgrade"],
            ["checkpoint", "create", "-s", "me-web"], ["checkpoint", "list", "-s", "me-web"]])

    def test_proxy_forwards_ports_and_the_supabase_preset(self):
        self.sprites("me-web")
        self.cli("proxy", "web", "5173", "3001:3000")
        self.cli("proxy", "web", "supabase")
        self.cli("proxy", "web", "http", ok=False)
        self.assertEqual([c["args"] for c in self.calls()], [
            ["proxy", "-s", "me-web", "5173", "3001:3000"],
            ["proxy", "-s", "me-web", "3000", "54321", "54323", "54324", "8000"]])

    def test_url_is_shown_and_never_made_public(self):
        self.sprites("me-web")
        self.assertIn("never makes it public", self.cli("url", "web").stdout)
        for path in (ROOT / "lib").glob("*.sh"):
            self.assertNotIn("public", path.read_text().replace("never makes it public", ""), path)

    def test_list_shows_only_this_handles_sprites_unless_all(self):
        self.sprites("me-web", "ann-api")
        self.assertIn("me-web", self.cli("list").stdout)
        self.assertNotIn("ann-api", self.cli("ls").stdout)
        self.assertIn("ann-api", self.cli("list", "--all").stdout)

    def test_check_runs_the_guest_check(self):
        self.sprites("me-web")
        self.cli("check", "web")
        self.assertEqual(self.execs(), [["bash", "/usr/local/share/boxen/check.sh"]])

    def test_the_organization_flag_reaches_every_call(self):
        self.env["BOXEN_SPRITE_ORG"] = "team"
        self.create("--plugins", "none")
        for call in self.calls(everything=True):
            words = 2 if call["args"][0] == "checkpoint" else 1
            self.assertEqual(call["args"][words:words + 2], ["-o", "team"], call["args"])

    def test_retired_commands_explain_themselves(self):
        for args, message in ((("stop", "web"), "sleep by themselves"), (("update-all",), "apt-get upgrade"),
                              (("tailscale", "join", "web"), "Tailscale is gone"), (("net", "web"), "bxn proxy")):
            self.assertIn(message, self.cli(*args, ok=False).stderr)

    def test_plugins_lists_the_index(self):
        out = self.cli("plugins").stdout
        self.assertRegex(out, r"gh-auth\s+default\s+GitHub token")
        self.assertRegex(out, r"nvchad\s{2,}Neovim")

    def test_doctor(self):
        out = self.cli("doctor").stdout
        self.assertIn("Logged in: yes", out)
        self.assertIn("Handle: me", out)
        self.env["FAKE_NOT_LOGGED_IN"] = "1"
        self.assertIn("sprite login", self.cli("doctor", ok=False).stdout)
        self.env["SPRITE_BIN"] = str(self.directory / "missing")
        self.assertIn("Install the sprite CLI", self.cli("doctor", ok=False).stderr)

    def test_symlinked_launcher_finds_its_files(self):
        link = self.directory / "bxn"
        link.symlink_to(ROOT / "bxn")
        self.assertIn("bxn create", self.cli("--help", launcher=link).stdout)

    # --- terminal -------------------------------------------------------------

    def tty(self, *args, script=()):
        """Run in a pseudo-terminal. script: (marker, input) pairs; each input is
        sent once its marker appears after the previous input."""
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(self.project)
            bash = os.environ.get("TEST_BASH", "bash")
            os.execvpe(bash, [bash, str(ROOT / "bxn"), *args], self.env)
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
        return [(b"Space: choose", bytes([k])) for k in keys]

    def test_selector_chooses_an_agent_and_plugins(self):
        # Rows: shell, claude, codex, grok, then plugins from gh-auth on; the
        # defaults start chosen, so Space on gh-auth turns it off.
        output, code = self.tty("create", "web", "acme/web", "--dry-run", script=self.keys(b"j jjj \r"))
        self.assertEqual(code, 0, output)
        self.assertIn("Agent: claude", output)
        self.assertIn("Plugins: " + ",".join(d for d in DEFAULTS if d != "gh-auth") + "\r\n", output)

    def test_selector_quits_without_creating(self):
        output, code = self.tty("create", "web", "acme/web", script=self.keys(b"q"))
        self.assertNotEqual(code, 0)
        self.assertIn("Aborted; nothing was created", output)
        self.assertFalse(any(c["args"][0] == "create" for c in self.calls(everything=True)))

    def test_keys_are_asked_for_and_never_echoed_or_passed_as_arguments(self):
        self.env["FAKE_LOGIN_STATUS"] = "10"
        output, code = self.tty(
            "create", "web", "acme/web", "--plugins", "gh-auth,1pass", "--agent", "codex",
            script=[(b"GitHub token", b"github_pat_fake\r"), (b"1Password token", b"ops_fake'$(x)\r"),
                    (b"Sign in to your subscription now?", b"\r")])
        self.assertEqual(code, 0, output)
        calls = self.calls()
        op = next(c for c in calls if c["args"][-1] == "OP_SERVICE_ACCOUNT_TOKEN")
        self.assertEqual(subprocess.run(["bash", "-c", op["stdin"] + 'printf %s "$OP_SERVICE_ACCOUNT_TOKEN"'],
                                        capture_output=True, text=True).stdout, "ops_fake'$(x)")
        for secret in ("github_pat_fake", "ops_fake"):
            self.assertNotIn(secret, json.dumps([c["args"] for c in calls]))
            self.assertNotIn(secret, output)
        # Codex signs in by device, then the agent starts: one command from login to agent.
        self.assertEqual(self.execs()[-2], ["bash", "/usr/local/share/boxen/agent-login.sh", "login"])
        self.assertIn("--tty", calls[-2]["args"])
        self.assertEqual(self.execs()[-1], ["bash", "/usr/local/share/boxen/agent-start.sh"])

    def test_a_terminal_create_ends_in_a_shell(self):
        output, code = self.tty("create", "web", "acme/web", "--plugins", "none")
        self.assertEqual(code, 0, output)
        self.assertEqual(self.execs()[-1], ["bash", "/usr/local/share/boxen/agent-start.sh", "--shell"])

    def test_a_failed_terminal_build_offers_to_destroy(self):
        self.env["FAKE_FAIL"] = "core-root.sh"
        output, code = self.tty("create", "web", "acme/web", "--plugins", "none", script=[(b"Destroy me-web?", b"\r")])
        self.assertNotEqual(code, 0)
        self.assertIn(["destroy", "--force", "me-web"], [c["args"] for c in self.calls()])

    def test_claude_gets_a_sign_in_hint_instead_of_an_offer(self):
        self.sprites("me-web")
        self.env.update(FAKE_LOGIN_STATUS="10", FAKE_LOGIN_AGENT="claude")
        output, code = self.tty("shell", "web")
        self.assertEqual(code, 0, output)
        self.assertIn("/login", output)
        self.assertNotIn(["bash", "/usr/local/share/boxen/agent-login.sh", "login"], self.execs())


if __name__ == "__main__":
    unittest.main()
