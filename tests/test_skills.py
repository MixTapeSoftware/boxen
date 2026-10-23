"""The repository's agent skills: one copy in .agents/skills, linked for
every agent, and the script that refreshes them from the skills repository."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CANONICAL = ROOT / ".agents/skills"
# Codex reads .agents/skills itself; these agents read their own folder.
AGENT_DIRS = (".claude/skills", ".grok/skills")


def skill_names(directory):
    return sorted(p.name for p in directory.iterdir() if not p.name.startswith("."))


class RepoSkills(unittest.TestCase):
    def test_botfight_is_a_repo_skill(self):
        self.assertTrue((CANONICAL / "botfight/SKILL.md").is_file())

    def test_every_agent_folder_links_every_skill_and_nothing_else(self):
        for agent_dir in AGENT_DIRS:
            folder = ROOT / agent_dir
            with self.subTest(folder=agent_dir):
                self.assertEqual(skill_names(folder), skill_names(CANONICAL))
                for name in skill_names(folder):
                    link = folder / name
                    self.assertTrue(link.is_symlink(), link)
                    # Relative, so the link works in any clone.
                    self.assertEqual(os.readlink(link), f"../../.agents/skills/{name}")
                    self.assertTrue((link / "SKILL.md").is_file(), link)

    def test_agents_md_names_the_checks_to_run_before_pushing(self):
        text = (ROOT / "AGENTS.md").read_text()
        self.assertIn("bash tests/run.sh", text)
        self.assertIn(".agents/skills", text)
        self.assertIn("--input", text)


class SyncSkills(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="boxen-skills-test-")
        self.addCleanup(temp.cleanup)
        self.directory = Path(temp.name)
        self.upstream = self.directory / "upstream"
        for name in ("botfight", "other"):
            (self.upstream / name / "references").mkdir(parents=True)
            (self.upstream / name / "SKILL.md").write_text(f"---\nname: {name}\n---\n")
            (self.upstream / name / "references/notes.md").write_text("notes\n")
        (self.upstream / "README.md").write_text("not a skill\n")
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.upstream)], check=True)
        subprocess.run(["git", "-C", str(self.upstream), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.upstream), "-c", "user.name=t", "-c", "user.email=t@t",
                        "commit", "-q", "-m", "skills"], check=True)
        self.repo = self.directory / "repo"
        (self.repo / ".agents/skills/local-only").mkdir(parents=True)
        (self.repo / ".agents/skills/local-only/SKILL.md").write_text("---\nname: local-only\n---\n")
        (self.repo / ".agents/skills/botfight").mkdir()
        (self.repo / ".agents/skills/botfight/stale.md").write_text("old\n")
        (self.repo / ".claude/skills").mkdir(parents=True)
        (self.repo / ".claude/skills/gone").symlink_to("../../.agents/skills/gone")

    def sync(self):
        env = dict(os.environ, BOXEN_SKILLS_REPO=str(self.upstream), BOXEN_SKILLS_ROOT=str(self.repo))
        result = subprocess.run(["bash", str(ROOT / "scripts/sync-skills.sh")], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_sync_copies_upstream_skills_and_links_every_skill_for_each_agent(self):
        self.sync()
        self.sync()
        skills = self.repo / ".agents/skills"
        self.assertEqual(skill_names(skills), ["botfight", "local-only", "other"])
        self.assertFalse((skills / "botfight/stale.md").exists())
        self.assertTrue((skills / "other/references").is_dir())
        for agent_dir in AGENT_DIRS:
            folder = self.repo / agent_dir
            self.assertEqual(skill_names(folder), ["botfight", "local-only", "other"])
            self.assertEqual(os.readlink(folder / "other"), "../../.agents/skills/other")
        self.assertFalse((self.repo / ".claude/skills/gone").is_symlink())


if __name__ == "__main__":
    unittest.main()
