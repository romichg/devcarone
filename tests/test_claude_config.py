"""Merge Plannotator's Claude Code hooks without disturbing user settings."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PLAN_REVIEW = {'matcher': 'ExitPlanMode', 'hooks': [
    {'type': 'command', 'command': '/usr/local/bin/plannotator', 'timeout': 345600}]}
IMPROVE = {'matcher': 'EnterPlanMode', 'hooks': [
    {'type': 'command', 'command': '/usr/local/bin/plannotator improve-context',
     'timeout': 5}]}


class ClaudeConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / 'claude with spaces'
        self.home.mkdir()
        self.settings = self.home / 'settings.json'

    def configure(self):
        return subprocess.run(
            [sys.executable, str(ROOT / 'configure-claude.py')],
            env=dict(os.environ, CLAUDE_CONFIG_DIR=str(self.home)),
            capture_output=True, text=True, timeout=5)

    def test_empty_home_and_repeated_startup(self):
        result = self.configure()
        self.assertEqual(result.returncode, 0, result.stderr)
        hooks = json.loads(self.settings.read_text())['hooks']
        self.assertEqual(hooks, {'PreToolUse': [IMPROVE], 'PermissionRequest': [PLAN_REVIEW]})
        before = self.settings.read_bytes()
        self.assertEqual(self.configure().returncode, 0)
        self.assertEqual(self.settings.read_bytes(), before)

    def test_existing_settings_and_hooks_survive(self):
        own = {'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': 'audit'}]}
        self.settings.write_text(json.dumps({'model': 'opus', 'hooks': {'PreToolUse': [own]}}))
        self.settings.chmod(0o600)
        self.assertEqual(self.configure().returncode, 0)
        settings = json.loads(self.settings.read_text())
        self.assertEqual(settings['model'], 'opus')
        self.assertEqual(settings['hooks']['PreToolUse'], [own, IMPROVE])
        self.assertEqual(self.settings.stat().st_mode & 0o777, 0o600)

    def test_existing_plannotator_hooks_are_not_duplicated(self):
        custom = {'matcher': 'ExitPlanMode', 'hooks': [
            {'type': 'command', 'command': 'plannotator --custom', 'timeout': 60}]}
        content = json.dumps({'hooks': {'PreToolUse': [IMPROVE],
                                        'PermissionRequest': [custom]}})
        self.settings.write_text(content)
        self.assertEqual(self.configure().returncode, 0)
        self.assertEqual(self.settings.read_text(), content)

    def test_malformed_settings_are_rejected_without_overwrite(self):
        for content in ('{not json', '[]', '{"hooks": []}',
                        '{"hooks": {"PermissionRequest": {}}}'):
            with self.subTest(content=content):
                self.settings.write_text(content)
                result = self.configure()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.settings.read_text(), content)

    def test_symlinked_settings_stay_a_link(self):
        real = self.home / 'real.json'
        real.write_text('{}')
        self.settings.symlink_to(real)
        self.assertEqual(self.configure().returncode, 0)
        self.assertTrue(self.settings.is_symlink())
        self.assertIn('ExitPlanMode', real.read_text())


if __name__ == '__main__':
    unittest.main()
