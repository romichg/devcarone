"""Check privilege drop and host GPU group propagation without root or a GUI."""
import json
import os
from pathlib import Path
import pwd
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps([name, *sys.argv[1:]]) + '\n')
if name == 'gosu':
    os.execvp(sys.argv[2], sys.argv[2:])
if name == 'urxvt':
    state = {key: os.environ.get(key) for key in
             ('HOME', 'USER', 'LOGNAME', 'SHELL', 'DISPLAY', 'XAUTHORITY', 'PULSE_SERVER')}
    print(json.dumps(dict(state, args=sys.argv[1:])))
'''


class EntrypointTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        for command in ('gosu', 'urxvt', 'groupadd', 'usermod'):
            path = self.base / command
            path.write_text(FAKE)
            path.chmod(0o755)
        self.calls_file = self.base / 'calls'
        self.user = pwd.getpwuid(os.getuid())
        self.tooling = self.base / 'tooling'
        (self.tooling / 'matt-pocock' / 'engineering' / 'tdd').mkdir(parents=True)
        (self.tooling / 'skills.list').write_text('matt-pocock/engineering/tdd\n')
        self.codex_skills = self.base / 'codex-skills'
        self.claude_home = self.base / 'claude'
        self.env = dict(os.environ, PATH=f'{self.base}:{ROOT / "desktop"}:' + os.environ['PATH'],
                        DEVCAR_USER=self.user.pw_name, LOCAL_UID=str(os.getuid()),
                        CALLS=str(self.calls_file), DISPLAY=':7',
                        CODEX_HOME=str(self.base / 'codex'),
                        CLAUDE_CONFIG_DIR=str(self.claude_home),
                        CODEX_SKILLS_DIR=str(self.codex_skills),
                        DEVCAR_TOOLING=str(self.tooling),
                        FORGEJO_TOKEN_PATH=str(self.base / 'absent-forgejo-token'),
                        GIT_CONFIG_SYSTEM=str(self.base / 'gitconfig'),
                        TEA_CONFIG_HOME=str(self.base / 'tea'),
                        XAUTHORITY='/tmp/test.xauth', PULSE_SERVER='/tmp/pulse/native')
        self.env.pop('RENDER_GID', None)
        self.env.pop('URXVT_FONT_SIZE', None)
        self.env.pop('DEVCAR_SKILLS', None)

    def launch(self):
        return subprocess.run(['bash', str(ROOT / 'entrypoint.sh'), 'x'],
                              env=self.env, capture_output=True, text=True, timeout=5)

    def test_x_terminal_runs_as_existing_user_with_display_and_audio(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(result.stdout)
        self.assertEqual(state['HOME'], self.user.pw_dir)
        self.assertEqual(state['USER'], self.user.pw_name)
        self.assertEqual(state['DISPLAY'], ':7')
        self.assertEqual(state['XAUTHORITY'], '/tmp/test.xauth')
        self.assertEqual(state['PULSE_SERVER'], '/tmp/pulse/native')
        calls = [json.loads(line) for line in self.calls_file.read_text().splitlines()]
        self.assertEqual(calls[0][:2], ['gosu', self.user.pw_name])
        self.assertIn('xft:DejaVu Sans Mono:size=13', state['args'])
        self.assertIn('URxvt.keysym.M-Up: \\033[1;3A', state['args'])

    def test_skills_are_linked_for_each_agent_and_can_be_switched_off(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        skill = self.tooling / 'matt-pocock' / 'engineering' / 'tdd'
        for directory in (self.codex_skills, self.claude_home / 'skills'):
            self.assertEqual(os.readlink(directory / 'tdd'), str(skill))
        hooks = json.loads((self.claude_home / 'settings.json').read_text())['hooks']
        self.assertEqual(set(hooks), {'PreToolUse', 'PermissionRequest'})
        self.env['DEVCAR_SKILLS'] = '0'
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        for directory in (self.codex_skills, self.claude_home / 'skills'):
            self.assertEqual(list(directory.iterdir()), [])
        self.env['DEVCAR_SKILLS'] = 'yes'
        self.assertEqual(self.launch().returncode, 2)

    def test_desktop_terminal_uses_vnc_font_size_and_extra_arguments(self):
        env = dict(self.env, URXVT_FONT_SIZE='8')
        result = subprocess.run([str(ROOT / 'desktop' / 'devcar-terminal'), '-geometry', '135x29'],
                                env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(result.stdout)['args']
        self.assertIn('xft:DejaVu Sans Mono:size=8:bold', args)
        self.assertEqual(args[-2:], ['-geometry', '135x29'])

    def test_mismatched_uid_stops_before_starting_application(self):
        self.env['LOCAL_UID'] = str(os.getuid() + 1)
        result = self.launch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('rebuild', result.stderr)
        self.assertFalse(self.calls_file.exists())

    def test_terminal_uses_account_shell_when_shell_is_missing_or_inherited(self):
        for inherited in (None, '/bin/sh'):
            with self.subTest(inherited=inherited):
                if inherited is None:
                    self.env.pop('SHELL', None)
                else:
                    self.env['SHELL'] = inherited
                result = self.launch()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)['SHELL'], self.user.pw_shell)

    def test_host_gpu_group_is_added_before_privilege_drop(self):
        self.env['RENDER_GID'] = '190'
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in self.calls_file.read_text().splitlines()]
        self.assertIn(['usermod', '-a', '-G', '190', self.user.pw_name], calls)
        added = calls.index(['usermod', '-a', '-G', '190', self.user.pw_name])
        dropped = next(i for i, c in enumerate(calls) if c[0] == 'gosu')
        self.assertLess(added, dropped)


if __name__ == '__main__':
    unittest.main()
