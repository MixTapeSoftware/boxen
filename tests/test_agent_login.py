"""Run the guest sign-in script on the host against fake claude and codex."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "v3/boxen/scripts/agent-login.sh"


class AgentLogin(unittest.TestCase):
    script = SCRIPT

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="boxen-login-test-")
        self.addCleanup(temp.cleanup)
        self.directory = Path(temp.name)
        self.log = self.directory / "calls"
        for tool in ("claude", "codex"):
            fake = self.directory / tool
            # Records the call; exits with FAKE_EXIT so status can report either way.
            fake.write_text(f'#!/bin/sh\necho "{tool} $*" >> {self.log}\nexit "${{FAKE_EXIT:-0}}"\n')
            fake.chmod(0o755)

    def run_script(self, agent, action, fake_exit=0):
        env = dict(os.environ, PATH=f"{self.directory}{os.pathsep}{os.environ['PATH']}",
                   BOXEN_AGENT=agent, FAKE_EXIT=str(fake_exit))
        result = subprocess.run(["bash", str(self.script), action], env=env, capture_output=True, text=True, timeout=10)
        calls = self.log.read_text().splitlines() if self.log.exists() else []
        self.log.unlink(missing_ok=True)
        if action == "status":
            # The host reads the agent's name from status to pick the sbx service.
            self.assertEqual(result.stdout, agent + "\n")
        return result.returncode, calls

    def test_status_asks_each_agent(self):
        self.assertEqual(self.run_script("claude", "status"), (0, ["claude auth status"]))
        self.assertEqual(self.run_script("claude", "status", fake_exit=1), (10, ["claude auth status"]))
        self.assertEqual(self.run_script("codex", "status", fake_exit=1), (10, ["codex login status"]))
        self.assertEqual(self.run_script("shell", "status"), (0, []))
        self.assertEqual(self.run_script("grok", "status"), (0, []))

    def test_login_uses_browserless_subscription_sign_in(self):
        self.assertEqual(self.run_script("claude", "login"), (0, ["claude auth login"]))
        self.assertEqual(self.run_script("codex", "login"), (0, ["codex login --device-auth"]))
        self.assertEqual(self.run_script("shell", "login")[0], 1)


if __name__ == "__main__":
    unittest.main()
