"""Protect mounted user configuration during repeat container startups."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[1]


class CodexConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / 'codex with spaces'
        self.home.mkdir()
        self.config = self.home / 'config.toml'
        self.hooks = self.home / 'hooks.json'

    def configure(self):
        return subprocess.run(
            [sys.executable, str(ROOT / 'configure-codex.py')],
            env=dict(os.environ, CODEX_HOME=str(self.home)),
            capture_output=True, text=True, timeout=5)

    def assert_configured(self):
        result = self.configure()
        self.assertEqual(result.returncode, 0, result.stderr)
        config = tomllib.loads(self.config.read_text())
        self.assertIs(config['features']['hooks'], True)
        return config

    def test_empty_home_and_repeated_startup(self):
        self.assert_configured()
        hook = json.loads(self.hooks.read_text())['hooks']['Stop'][0]['hooks'][0]
        self.assertEqual(hook, {'type': 'command',
                                'command': '/usr/local/bin/plannotator',
                                'timeout': 345600})
        before = [p.read_bytes() for p in (self.config, self.hooks)]
        self.assert_configured()
        self.assertEqual(before, [p.read_bytes() for p in (self.config, self.hooks)])

    def test_existing_settings_comments_and_other_hooks_survive(self):
        self.config.write_text('# Keep my settings\nmodel = "chosen-model"\n'
                               '[features] # Keep this comment\n'
                               'codex_hooks = false\nmulti_agent = true\n'
                               '[projects."/workspace"]\ntrust_level = "trusted"\n')
        other = {'hooks': [{'type': 'command', 'command': 'my-stop-command'}]}
        self.hooks.write_text(json.dumps({'description': 'My hooks',
                                         'hooks': {'Stop': [other], 'SessionStart': [other]}}))
        config = self.assert_configured()
        self.assertEqual(config['model'], 'chosen-model')
        self.assertTrue(config['features']['multi_agent'])
        self.assertNotIn('codex_hooks', config['features'])
        self.assertEqual(config['projects']['/workspace']['trust_level'], 'trusted')
        self.assertIn('# Keep this comment', self.config.read_text())
        hooks = json.loads(self.hooks.read_text())
        self.assertEqual(hooks['description'], 'My hooks')
        self.assertEqual(hooks['hooks']['Stop'][0], other)
        self.assertEqual(hooks['hooks']['SessionStart'], [other])
        self.assertEqual(len(hooks['hooks']['Stop']), 2)

    def test_inline_features_and_hooks_remain_inline_and_idempotent(self):
        self.config.write_text('features = { hooks = false, multi_agent = true }\n'
                               '[[hooks.SessionStart]]\n'
                               'hooks = [{ type = "command", command = "startup" }]\n')
        config = self.assert_configured()
        self.assertTrue(config['features']['multi_agent'])
        self.assertEqual(config['hooks']['SessionStart'][0]['hooks'][0]['command'], 'startup')
        self.assertEqual(config['hooks']['Stop'][0]['hooks'][0]['command'],
                         '/usr/local/bin/plannotator')
        self.assertFalse(self.hooks.exists())
        before = self.config.read_bytes()
        self.assert_configured()
        self.assertEqual(self.config.read_bytes(), before)
        self.assertFalse(self.hooks.exists())

    def test_custom_plannotator_hook_is_preserved_without_duplicate(self):
        self.hooks.write_text(json.dumps({'hooks': {'Stop': [{'hooks': [{
            'type': 'command', 'command': '/usr/bin/env CUSTOM=1 /usr/local/bin/plannotator',
            'timeout': 900
        }]}]}}))
        before = self.hooks.read_bytes()
        self.assert_configured()
        self.assertEqual(self.hooks.read_bytes(), before)

    def test_old_binary_path_is_updated_without_duplicate(self):
        self.hooks.write_text(json.dumps({'hooks': {'Stop': [{'hooks': [{
            'type': 'command', 'command': '/home/dev/.local/bin/plannotator', 'timeout': 900
        }]}]}}))
        self.assert_configured()
        groups = json.loads(self.hooks.read_text())['hooks']['Stop']
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0]['hooks'][0]['command'], '/usr/local/bin/plannotator')
        self.assertEqual(groups[0]['hooks'][0]['timeout'], 345600)

    def test_invalid_configuration_leaves_both_files_untouched(self):
        for config, hooks in [('broken = [', '{}'),
                              ('model = "keep"\n', '{broken'),
                              ('model = "keep"\n', '{"hooks":{"Stop":{}}}')]:
            with self.subTest(config=config, hooks=hooks):
                self.config.write_text(config)
                self.hooks.write_text(hooks)
                result = self.configure()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.config.read_text(), config)
                self.assertEqual(self.hooks.read_text(), hooks)

    def test_symlinked_config_keeps_link_and_target_permissions(self):
        target = self.home.parent / 'shared.toml'
        target.write_text('model = "keep"\n')
        target.chmod(0o640)
        self.config.symlink_to(target)
        self.assert_configured()
        self.assertTrue(self.config.is_symlink())
        self.assertEqual(target.stat().st_mode & 0o777, 0o640)


if __name__ == '__main__':
    unittest.main()
