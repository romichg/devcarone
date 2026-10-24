"""Exercise the launcher without Docker, sudo, or a host X server.

The external command recorder lets us check mount arguments and cleanup order;
all argument parsing, filesystem operations, and signal handling are real.
"""
import json
import os
import pwd
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, time
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps([name, *args]) + '\n')
if name == 'sudo':
    # Run the detached cleanup watcher in place unless a test keeps it away.
    # Like setsid -f, report success whatever the watcher's own status.
    if args[:2] == ['setsid', '-f'] and not os.environ.get('SKIP_WATCHER'):
        import subprocess
        subprocess.run(args[2:])
    sys.exit(0)
if name == 'ssh-keygen':
    key = pathlib.Path(args[args.index('-f') + 1])
    key.write_text('private host key')
    key.with_name(key.name + '.pub').write_text('ssh-ed25519 host-key devcarone')
if name == 'stat':
    print('190')
if name == 'xauth':
    if args[0] == 'nlist':
        print('0100 0000 0000 0000 0000')
    else:
        pathlib.Path(args[1]).write_text(sys.stdin.read())
if name == 'docker':
    if args[0] == 'create':
        with open(os.environ['GOG_ENV_CAPTURE'], 'w') as f:
            json.dump({k: os.environ.get(k) for k in
                       ('GOG_HOME', 'GOG_ACCOUNT', 'GOG_KEYRING_BACKEND', 'GOG_KEYRING_PASSWORD')}, f)
        if os.environ.get('FAIL_CREATE'):
            sys.exit(42)
        pathlib.Path(args[args.index('--cidfile') + 1]).write_text('test-container')
        print('test-container')
    elif args[0] == 'inspect':
        print(os.environ.get('DEVCAR_IP') or '172.17.0.2')
    elif args[0] == 'wait':
        print(os.environ.get('CONTAINER_STATUS', '0'))
    elif args[0] == 'ps':
        print('\n'.join(filter(None, os.environ.get('USED_PORTS', '').split(','))))
    elif args[0] == 'logs':
        print('container output')
    elif args[0] == 'container':
        sys.exit(0 if os.environ.get('CONTAINER_REMAINS') else 1)
'''


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='devcar test ')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        for command in ('docker', 'sudo', 'xauth', 'stat', 'ssh-keygen', 'umount'):
            path = self.bin / command
            path.write_text(FAKE)
            path.chmod(0o755)
        self.main = self.base / 'state'
        config = self.main / 'master_config'
        config.mkdir(parents=True)
        for directory in ('config', 'pki', 'vscode', 'codex', 'claude'):
            (config / directory).mkdir()
        (config / 'Xresources').write_text('Xft.dpi: 168\n')
        self.calls_file = self.base / 'calls'
        self.env = dict(os.environ, PATH=f'{self.bin}:' + os.environ['PATH'],
                        MAINDIR=str(self.main), DISPLAY=':7',
                        TMPDIR=str(self.base), CALLS=str(self.calls_file),
                        GOG_ENV_CAPTURE=str(self.base / 'gog-env'),
                        DEVCAR_ENV_FILE='')
        for key in ('USED_PORTS', 'SKIP_WATCHER', 'CONTAINER_REMAINS', 'GOGCLI_STATE_HOME', 'GOG_HOME', 'GOG_ACCOUNT',
                    'GOG_KEYRING_BACKEND', 'GOG_KEYRING_PASSWORD',
                    'DEVCAR_IP', 'SSH_HOST_KEY_DIR', 'FORGEJO_URL',
                    'FORGEJO_USER', 'FORGEJO_TOKEN_FILE', 'DEVCAR_SKILLS',
                    'NETWORK', 'DNS'):
            self.env.pop(key, None)

    def calls(self):
        if not self.calls_file.exists():
            return []
        return [json.loads(line) for line in self.calls_file.read_text().splitlines()]

    def launch(self, *args, launcher=ROOT / 'devcarone'):
        self.assertTrue(launcher.is_file(), 'standalone launcher is missing')
        return subprocess.run(['bash', str(launcher), *args],
                              cwd=self.base, env=self.env, capture_output=True,
                              text=True, timeout=10)

    def create_args(self):
        return next(c for c in self.calls() if c[:2] == ['docker', 'create'])

    def session_log(self):
        return next(self.main.glob('*/session.log')).read_text()

    def test_x_mounts_survive_spaces_and_cleanup_follows_container_removal(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.create_args()
        self.assertIn(f'{self.base}:/home/{pwd.getpwuid(os.getuid()).pw_name}/src', args)
        self.assertIn('/tmp/.X11-unix:/tmp/.X11-unix:ro', args)
        self.assertIn('RENDER_GID=190', args)
        self.assertFalse(any('authorized_keys' in a for a in args))
        self.assertFalse(any('/media/incoming' in a or '/media/outgoing' in a for a in args))
        auth = next(a.split('=', 1)[1] for a in args if a.startswith('XAUTHORITY='))
        self.assertFalse(Path(auth).exists(), 'temporary Xauthority leaked')
        calls = self.calls()
        started = calls.index(['docker', 'start', 'test-container'])
        watcher = next(i for i, c in enumerate(calls) if c[:3] == ['sudo', 'setsid', '-f'])
        removed = next(i for i, c in enumerate(calls) if c[:3] == ['docker', 'rm', '-f'])
        unmounted = next(i for i, c in enumerate(calls) if c[0] == 'umount')
        self.assertLess(started, watcher)
        self.assertLess(watcher, removed)
        self.assertLess(removed, unmounted)
        self.assertIn('container output', self.session_log())

    def test_vnc_needs_dedicated_keys_before_mounting(self):
        result = self.launch('--vnc')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('authorized_keys', result.stderr)
        self.assertFalse(any(c[:2] == ['sudo', 'mount'] for c in self.calls()))

    def test_vnc_works_without_host_display_and_prints_ssh_tunnel(self):
        (self.main / 'authorized_keys').write_text('ssh-ed25519 test-key\n')
        self.env.pop('DISPLAY')
        result = self.launch('--vnc')
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.create_args()
        self.assertIn(f'{self.main}/authorized_keys:/run/devcar/authorized_keys:ro', args)
        self.assertIn('vnc', args)
        self.assertFalse(any('.X11-unix' in a or 'XAUTHORITY=' in a for a in args))
        self.assertFalse(any(c[0] == 'xauth' for c in self.calls()))
        self.assertIn('ssh -N -L 15999:127.0.0.1:5999', result.stdout)
        self.assertIn('127.0.0.1:15999', result.stdout)
        self.assertIn('ssh -N -J', result.stdout)
        self.assertIn('172.17.0.2', result.stdout)
        self.assertIn(f'devcarone.user={pwd.getpwuid(os.getuid()).pw_name}', args)
        self.assertIn('devcarone-ssh ', result.stdout)
        self.assertIn('--name', result.stdout)
        self.assertFalse(any(a == '--ip' for a in args))
        self.assertIn('VNC_FONT_SIZE=8', args)

    def test_vnc_host_key_is_created_once_and_mounted(self):
        (self.main / 'authorized_keys').write_text('ssh-ed25519 test-key\n')
        key = self.main / 'ssh_host_keys' / 'ssh_host_ed25519_key'
        for _ in range(2):
            result = self.launch('--vnc')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f'{key}:/run/devcar/ssh_host_ed25519_key:ro', self.create_args())
        self.assertEqual(sum(c[0] == 'ssh-keygen' for c in self.calls()), 1)
        self.assertEqual(key.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(key.read_text(), 'private host key')

    def test_static_ip_is_requested_and_printed(self):
        (self.main / 'authorized_keys').write_text('ssh-ed25519 test-key\n')
        self.env['DEVCAR_IP'] = '172.30.0.10'
        result = self.launch('--vnc')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('NETWORK', result.stderr)
        self.assertFalse(any(c[:2] == ['sudo', 'mount'] for c in self.calls()))
        self.env['NETWORK'] = 'devnet'
        result = self.launch('--vnc')
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.create_args()
        self.assertEqual(args[args.index('--ip') + 1], '172.30.0.10')
        self.assertIn('172.30.0.10', result.stdout)

    def test_named_session_sets_container_and_ssh_name(self):
        (self.main / 'authorized_keys').write_text('ssh-ed25519 test-key\n')
        for args in (('--name', 'work', '--vnc'), ('--vnc', '--name=work')):
            with self.subTest(args=args):
                result = self.launch(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                create = self.create_args()
                self.assertEqual(create[create.index('--name') + 1], 'devcarone-work')
                self.assertEqual(create[create.index('--hostname') + 1], 'devcarone-work')
                self.assertRegex(result.stdout, r'devcarone-ssh \S+ work\n')
                self.assertIn('docker stop devcarone-work', result.stdout)
                self.assertNotIn('Use --name', result.stdout)
                self.calls_file.unlink()
        self.assertTrue(list(self.main.glob('*_work_*/session.log')))

    def test_vnc_sessions_get_distinct_tunnel_ports(self):
        (self.main / 'authorized_keys').write_text('ssh-ed25519 test-key\n')
        for used, port in (('', '15999'), ('15999,16001', '16000'), ('15999,16000', '16001')):
            with self.subTest(used=used):
                self.env['USED_PORTS'] = used
                result = self.launch('--vnc')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f'devcarone.vnc-port={port}', self.create_args())
                self.assertIn(f'-L {port}:127.0.0.1:5999', result.stdout)
                self.assertIn(f'viewer to 127.0.0.1:{port}.', result.stdout)
                self.calls_file.unlink()
        result = self.launch()
        self.assertFalse(any(a.startswith('devcarone.vnc-port') for a in self.create_args()))

    def test_invalid_or_taken_name_fails_before_mounting(self):
        for args in (('--name',), ('--name', 'Work'), ('--name', '-x'),
                     ('--name', 'a_b'), ('--name', 'x' * 33), ('--name=',)):
            with self.subTest(args=args):
                result = self.launch(*args)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(any(c[:2] == ['sudo', 'mount'] for c in self.calls()))
        self.env['CONTAINER_REMAINS'] = '1'  # The fake reports an existing container.
        result = self.launch('--name', 'work')
        self.assertEqual(result.returncode, 1)
        self.assertIn('already exists', result.stderr)
        self.assertFalse(any(c[:2] == ['sudo', 'mount'] for c in self.calls()))

    def test_invalid_host_key_dir_fails_before_mounting(self):
        (self.main / 'authorized_keys').write_text('ssh-ed25519 test-key\n')
        self.env['SSH_HOST_KEY_DIR'] = 'relative'
        result = self.launch('--vnc')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SSH_HOST_KEY_DIR', result.stderr)
        self.assertFalse(any(c[:2] == ['sudo', 'mount'] for c in self.calls()))

    def test_forgejo_token_is_mounted_only_when_present(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any('forgejo' in a.lower() for a in self.create_args()))
        token = self.main / 'forgejo' / 'token'
        token.parent.mkdir()
        token.write_text('fake-forgejo-token\n')
        self.calls_file.unlink()
        self.env.update(FORGEJO_URL='https://forgejo.example:3000', FORGEJO_USER='dev')
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.create_args()
        self.assertIn(f'{token}:/run/devcar/forgejo-token:ro', args)
        self.assertIn('FORGEJO_URL=https://forgejo.example:3000', args)
        self.assertIn('FORGEJO_USER=dev', args)
        self.assertNotIn('fake-forgejo-token', self.calls_file.read_text() + result.stdout)

    def test_invalid_forgejo_settings_fail_before_mounting(self):
        token = self.main / 'forgejo' / 'token'
        token.parent.mkdir()
        token.write_text('fake-forgejo-token\n')
        self.env.update(FORGEJO_URL='https://forgejo.example', FORGEJO_USER='dev')
        for settings in ({'FORGEJO_URL': 'http://insecure.example'},
                         {'FORGEJO_URL': ''}, {'FORGEJO_USER': 'bad"user'}):
            with self.subTest(settings=settings):
                self.env.update(settings)
                result = self.launch()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(c[:2] == ['sudo', 'mount'] for c in self.calls()))
                self.env.update(FORGEJO_URL='https://forgejo.example', FORGEJO_USER='dev')

    def test_network_and_dns_are_passed_only_when_set(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.create_args()
        self.assertNotIn('--network', args)
        self.assertNotIn('--dns', args)
        self.calls_file.unlink()
        self.env.update(NETWORK='devnet', DNS='10.0.0.53')
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.create_args()
        self.assertEqual(args[args.index('--network') + 1], 'devnet')
        self.assertEqual(args[args.index('--dns') + 1], '10.0.0.53')

    def test_settings_file_beside_launcher_applies_and_environment_wins(self):
        directory = self.base / 'install dir'
        directory.mkdir()
        shutil.copy(ROOT / 'devcarone', directory / 'devcarone')
        (directory / 'devcarone.env').write_text(
            '# site settings\n\n'
            'NETWORK=file-net\n'
            'DNS=10.0.0.53\n'
            'FORGEJO_USER=Value with spaces\n')
        link = self.bin / 'devcarone-link'
        link.symlink_to(directory / 'devcarone')
        self.env.pop('DEVCAR_ENV_FILE')
        self.env['DNS'] = '10.9.9.9'
        result = self.launch(launcher=link)
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.create_args()
        self.assertEqual(args[args.index('--network') + 1], 'file-net')
        self.assertEqual(args[args.index('--dns') + 1], '10.9.9.9')

    def test_example_settings_file_is_valid(self):
        settings = self.base / 'example.env'
        settings.write_text((ROOT / 'devcarone.env.example').read_text())
        self.env['DEVCAR_ENV_FILE'] = str(settings)
        result = self.launch()  # MAINDIR from the test environment wins.
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_or_missing_settings_file_fails_before_mounting(self):
        settings = self.base / 'site.env'
        for content in ('PATH=/tmp/evil\n', 'NETWORK = spaced\n', 'not a setting\n',
                        'GOG_KEYRING_PASSWORD=secret\n', None):
            with self.subTest(content=content):
                settings.unlink(missing_ok=True)
                if content is not None:
                    settings.write_text(content)
                self.env['DEVCAR_ENV_FILE'] = str(settings)
                result = self.launch()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(c[:2] == ['sudo', 'mount'] for c in self.calls()))

    def test_skill_switch_is_passed_and_validated(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('DEVCAR_SKILLS=1', self.create_args())
        self.calls_file.unlink()
        self.env['DEVCAR_SKILLS'] = '0'
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('DEVCAR_SKILLS=0', self.create_args())
        self.calls_file.unlink()
        self.env['DEVCAR_SKILLS'] = 'no'
        result = self.launch()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[:2] == ['sudo', 'mount'] for c in self.calls()))

    def test_create_failure_unmounts_and_preserves_failure_status(self):
        self.env['FAIL_CREATE'] = '1'
        result = self.launch()
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertTrue(any(c[:2] == ['sudo', 'umount'] for c in self.calls()))
        self.assertFalse(list(self.base.glob('.docker.xauth.*')))

    def test_gog_auth_persists_and_password_is_passed_only_by_environment(self):
        self.env.update(GOG_ACCOUNT='test@example.com', GOG_KEYRING_PASSWORD='fake-test-secret')
        for mode in ((), ('--vnc',)):
            (self.main / 'authorized_keys').write_text('ssh-ed25519 test-key\n')
            result = self.launch(*mode)
            self.assertEqual(result.returncode, 0, result.stderr)
            state = self.main / 'gogcli'
            self.assertEqual(state.stat().st_mode & 0o777, 0o700)
            marker = state / 'retained'
            if mode:
                self.assertEqual(marker.read_text(), 'keep')
            marker.write_text('keep')
            captured = json.loads((self.base / 'gog-env').read_text())
            self.assertEqual(captured['GOG_KEYRING_PASSWORD'], 'fake-test-secret')
            self.assertEqual(captured['GOG_ACCOUNT'], 'test@example.com')
            self.assertEqual(captured['GOG_KEYRING_BACKEND'], 'file')
            self.assertIn(f"{state}:{captured['GOG_HOME']}", self.create_args())
            self.assertNotIn('fake-test-secret', self.calls_file.read_text() + result.stdout + result.stderr)
            self.calls_file.unlink()

    def test_gog_custom_paths_preserve_existing_permissions(self):
        state = self.base / 'custom auth'
        state.mkdir(mode=0o750)
        self.env.update(GOGCLI_STATE_HOME=str(state), GOG_HOME='/tmp/custom gog')
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'{state}:/tmp/custom gog', self.create_args())
        self.assertEqual(state.stat().st_mode & 0o777, 0o750)

    def test_gog_missing_password_or_invalid_path_fails_before_mounting(self):
        for settings in ({'GOG_ACCOUNT': 'test@example.com'},
                         {'GOGCLI_STATE_HOME': 'relative'},
                         {'GOG_HOME': '/tmp/invalid:path'}):
            with self.subTest(settings=settings):
                self.env.update(settings)
                result = self.launch()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(c[:2] == ['sudo', 'mount'] for c in self.calls()))
                self.env.update(FORGEJO_URL='https://forgejo.example', FORGEJO_USER='dev')

    def test_launcher_returns_while_container_runs(self):
        self.env['SKIP_WATCHER'] = '1'
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertFalse(any(c[:2] in (['docker', 'rm'], ['docker', 'wait'],
                                       ['sudo', 'umount']) for c in calls))
        auth = next(a.split('=', 1)[1] for a in self.create_args()
                    if a.startswith('XAUTHORITY='))
        self.assertTrue(Path(auth).exists(), 'running container lost its Xauthority')
        self.assertIn('docker stop devcarone-', result.stdout)

    def test_container_status_is_logged(self):
        self.env['CONTAINER_STATUS'] = '17'
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('exited with status 17', self.session_log())

    def test_watcher_keeps_overlay_when_container_cannot_be_removed(self):
        self.env['CONTAINER_REMAINS'] = '1'
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(c[0] == 'umount' for c in self.calls()))
        self.assertIn('overlay retained', self.session_log())

    def test_watcher_failure_stops_container_before_unmounting(self):
        self.env['SKIP_WATCHER'] = '1'
        (self.bin / 'sudo').write_text(FAKE.replace(
            "if name == 'sudo':", "if name == 'sudo' and args[0] == 'setsid':\n    sys.exit(1)\nif name == 'sudo':"))
        result = self.launch()
        self.assertNotEqual(result.returncode, 0)
        calls = self.calls()
        removed = next(i for i, c in enumerate(calls) if c[:3] == ['docker', 'rm', '-f'])
        unmounted = next(i for i, c in enumerate(calls) if c[:2] == ['sudo', 'umount'])
        self.assertLess(removed, unmounted)

if __name__ == '__main__':
    unittest.main()
