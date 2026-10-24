"""Keep image skill links current without touching the user's own skills."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SkillLinkTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='skills test ')
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)
        self.tooling = base / 'tooling'
        self.skills = {}
        for path in ('matt-pocock/engineering/tdd', 'matt-pocock/productivity/grill-me',
                     'plannotator/plannotator-review'):
            (self.tooling / path).mkdir(parents=True)
            (self.tooling / path / 'SKILL.md').write_text('---\nname: x\n---\n')
            self.skills[path.rsplit('/', 1)[1]] = self.tooling / path
        (self.tooling / 'skills.list').write_text(''.join(f'{p}\n' for p in (
            'matt-pocock/engineering/tdd', 'matt-pocock/productivity/grill-me',
            'plannotator/plannotator-review')))
        self.target = base / 'home dir' / '.claude' / 'skills'

    def link(self, state='on'):
        return subprocess.run(['bash', str(ROOT / 'link-skills.sh'), str(self.target), state],
                              env=dict(os.environ, DEVCAR_TOOLING=str(self.tooling)),
                              capture_output=True, text=True, timeout=5)

    def links(self):
        return {p.name: os.readlink(p) for p in self.target.iterdir() if p.is_symlink()}

    def test_links_every_listed_skill_and_repeats_cleanly(self):
        result = self.link()
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = {name: str(path) for name, path in self.skills.items()}
        self.assertEqual(self.links(), expected)
        result = self.link()
        self.assertEqual((result.returncode, result.stderr), (0, ''))
        self.assertEqual(self.links(), expected)

    def test_user_skills_are_kept_and_stale_image_links_removed(self):
        self.target.mkdir(parents=True)
        (self.target / 'tdd').mkdir()
        (self.target / 'tdd' / 'SKILL.md').write_text('mine\n')
        (self.target / 'grill-me').symlink_to('/somewhere/else')
        (self.target / 'retired').symlink_to(self.tooling / 'matt-pocock' / 'retired')
        (self.target / 'moved').symlink_to(self.tooling / 'old' / 'plannotator-review')
        result = self.link()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.target / 'tdd' / 'SKILL.md').read_text(), 'mine\n')
        self.assertEqual(self.links(), {
            'grill-me': '/somewhere/else',
            'plannotator-review': str(self.skills['plannotator-review'])})
        self.assertIn('tdd', result.stderr)
        self.assertIn('grill-me', result.stderr)

    def test_off_removes_only_image_links(self):
        self.link()
        (self.target / 'mine').mkdir()
        (self.target / 'other').symlink_to('/somewhere/else')
        result = self.link('off')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(p.name for p in self.target.iterdir()), ['mine', 'other'])

    def test_off_without_directory_creates_nothing(self):
        result = self.link('off')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.target.exists())


if __name__ == '__main__':
    unittest.main()
