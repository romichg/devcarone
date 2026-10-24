"""Check Forgejo startup configuration and the git credential helper without root."""
import os
from pathlib import Path
import pwd
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
URL = 'https://forgejo.example.test:5000'
TOKEN = '0123456789abcdef0123456789abcdef01234567'


class ForgejoTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        gosu = self.base / 'gosu'
        gosu.write_text('#!/bin/sh\nshift\nexec "$@"\n')
        gosu.chmod(0o755)
        self.token = self.base / 'token'
        self.token.write_text(TOKEN + '\n')
        self.gitconfig = self.base / 'gitconfig'
        self.env = dict(os.environ, PATH=f'{self.base}:' + os.environ['PATH'],
                        DEVCAR_USER=pwd.getpwuid(os.getuid()).pw_name,
                        FORGEJO_URL=URL + '/', FORGEJO_USER='dev',
                        FORGEJO_TOKEN_PATH=str(self.token),
                        TEA_CONFIG_HOME=str(self.base / 'tea home'),
                        GIT_CONFIG_SYSTEM=str(self.gitconfig),
                        GIT_CONFIG_GLOBAL=os.devnull, HOME=str(self.base))

    def configure(self):
        return subprocess.run([str(ROOT / 'forgejo' / 'configure-forgejo.sh')], env=self.env,
                              capture_output=True, text=True, timeout=10)

    def git_config(self, key):
        return subprocess.run(['git', 'config', '--system', key], env=self.env,
                              capture_output=True, text=True, check=True).stdout.strip()

    def test_startup_writes_private_tea_login_and_scoped_helper(self):
        for _ in range(2):
            result = self.configure()
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git_config(f'credential.{URL}.username'), 'dev')
        self.assertTrue(self.git_config(f'credential.{URL}.helper').endswith('forgejo-credential'))
        self.assertNotIn(TOKEN, self.gitconfig.read_text())
        config = self.base / 'tea home' / 'tea' / 'config.yml'
        self.assertEqual(config.stat().st_mode & 0o777, 0o600)
        self.assertEqual(config.parent.stat().st_mode & 0o777, 0o700)
        text = config.read_text()
        self.assertIn(f'url: "{URL}"', text)
        self.assertIn(f'token: "{TOKEN}"', text)
        self.assertEqual(text.count('- name:'), 1)

    def test_malformed_token_is_rejected_without_tea_login(self):
        self.token.write_text('not a token"\nsecond line\n')
        result = self.configure()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('not a token', result.stdout + result.stderr)
        self.assertFalse((self.base / 'tea home' / 'tea' / 'config.yml').exists())

    def test_helper_answers_get_only(self):
        helper = str(ROOT / 'forgejo' / 'forgejo-credential')
        request = f'protocol=https\nhost=forgejo.example.test:5000\nusername=dev\n\n'
        get = subprocess.run([helper, 'get'], input=request, env=self.env,
                             capture_output=True, text=True, check=True)
        self.assertEqual(get.stdout, f'password={TOKEN}\n')
        for action in ('store', 'erase'):
            other = subprocess.run([helper, action], input=request + 'password=x\n',
                                   env=self.env, capture_output=True, text=True, check=True)
            self.assertEqual(other.stdout, '')
        self.assertEqual(self.token.read_text(), TOKEN + '\n')

    def test_git_uses_helper_only_for_the_configured_server(self):
        result = self.configure()
        self.assertEqual(result.returncode, 0, result.stderr)
        # Point the configured absolute helper path at the repository copy.
        subprocess.run(['git', 'config', '--system', f'credential.{URL}.helper',
                        str(ROOT / 'forgejo' / 'forgejo-credential')], env=self.env, check=True)
        env = dict(self.env, GIT_TERMINAL_PROMPT='0', GIT_ASKPASS='/bin/false')
        fill = subprocess.run(['git', 'credential', 'fill'], env=env, text=True,
                              input=f'url={URL}/owner/repo.git\n\n', capture_output=True)
        self.assertEqual(fill.returncode, 0, fill.stderr)
        self.assertIn('username=dev\n', fill.stdout)
        self.assertIn(f'password={TOKEN}\n', fill.stdout)
        other = subprocess.run(['git', 'credential', 'fill'], env=env, text=True,
                               input='url=https://other.example.test/repo.git\n\n',
                               capture_output=True)
        self.assertNotIn(TOKEN, other.stdout)


if __name__ == '__main__':
    unittest.main()
