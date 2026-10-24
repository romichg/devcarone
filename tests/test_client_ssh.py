"""Check client/devcarone-ssh with substitute ssh and docker commands."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
# The fake ssh records its arguments. Like real ssh, it reads stdin unless
# given -n: a lookup passes stdin to the remote command, and -W forwards it,
# so the tests see whether the client's stream reaches the container intact.
FAKE_SSH = r'''#!/bin/sh
printf '%s\n' "$*" >> "$CALLS"
for arg; do [ "$arg" = -W ] && { cat > "$FORWARDED"; echo forwarded; exit 0; }; done
case "$*" in *ProxyCommand=*) echo session; exit 0 ;; esac
stdin=yes
while case $1 in -n) stdin=no ;; -o) shift ;; *) false ;; esac; do shift; done
shift
if [ $stdin = yes ]; then exec sh -c "$*"; else exec sh -c "$*" < /dev/null; fi
'''
FAKE_DOCKER = r'''#!/bin/sh
[ "$1 $2" = 'inspect --format' ] || exit 9
[ "$3" = '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}/{{index .Config.Labels "devcarone.vnc-port"}}/{{index .Config.Labels "devcarone.user"}}' ] || exit 8
cat > /dev/null  # Consumes whatever ssh passes on, as a remote command can.
case $4 in
    devcarone-work) echo 172.30.0.5/16000/dev ;;
    devcarone-xmode) echo 172.30.0.6// ;;
    *) echo "Error: No such object: $4" >&2; exit 1 ;;
esac
'''
STREAM = 'SSH-2.0-OpenSSH_10.0\r\nKEXINIT...'


class ClientSshTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='client test ')
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)
        bin_dir = base / 'bin'
        bin_dir.mkdir()
        for name, text in (('ssh', FAKE_SSH), ('docker', FAKE_DOCKER)):
            (bin_dir / name).write_text(text)
            (bin_dir / name).chmod(0o755)
        self.calls = base / 'calls'
        self.forwarded = base / 'forwarded'
        self.env = dict(os.environ, PATH=f'{bin_dir}:' + os.environ['PATH'],
                        CALLS=str(self.calls), FORWARDED=str(self.forwarded))

    def run_client(self, *args):
        return subprocess.run([str(ROOT / 'client' / 'devcarone-ssh'), *args],
                              input=STREAM, env=self.env, capture_output=True,
                              text=True, timeout=5)

    def recorded(self):
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def test_shell_with_vnc_forward_in_two_host_connections(self):
        for name in ('work', 'devcarone-work'):
            with self.subTest(name=name):
                self.calls.unlink(missing_ok=True)
                result = self.run_client('dockerhost', name)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('127.0.0.1:16000', result.stderr)
                lookup, session = self.recorded()
                self.assertTrue(lookup.startswith('-n -o ClearAllForwardings=yes dockerhost '))
                self.assertEqual(session, '-o ProxyCommand=ssh -W 172.30.0.5:22 dockerhost '
                                          '-o HostKeyAlias=devcarone -l dev '
                                          '-L 16000:127.0.0.1:5999 devcarone-work')
                self.assertNotIn('ExitOnForwardFailure', session)

    def test_command_is_passed_to_the_session(self):
        result = self.run_client('dockerhost', 'work', 'uname', '-a')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.recorded()[-1].endswith('devcarone-work uname -a'))

    def test_proxy_mode_forwards_the_whole_stream(self):
        result = self.run_client('--proxy', 'dockerhost', 'devcarone-work')
        self.assertEqual(result.returncode, 0, result.stderr)
        # The lookup must not consume the client's stream; all of it is forwarded.
        self.assertEqual(self.forwarded.read_bytes(), STREAM.encode())
        lookup, forward = self.recorded()
        self.assertTrue(lookup.startswith('-n -o ClearAllForwardings=yes dockerhost '))
        self.assertEqual(forward, '-W 172.30.0.5:22 dockerhost')

    def test_proxy_mode_works_for_x_sessions_but_shell_mode_refuses(self):
        result = self.run_client('--proxy', 'dockerhost', 'devcarone-xmode')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.calls.unlink()
        result = self.run_client('dockerhost', 'xmode')
        self.assertEqual(result.returncode, 1)
        self.assertIn('not a --vnc session', result.stderr)
        self.assertEqual(len(self.recorded()), 1)

    def test_missing_container_fails_after_lookup(self):
        for args in (('dockerhost', 'gone'), ('--proxy', 'dockerhost', 'devcarone-gone')):
            with self.subTest(args=args):
                self.calls.unlink(missing_ok=True)
                result = self.run_client(*args)
                self.assertEqual(result.returncode, 1)
                self.assertIn('No such object', result.stderr)
                self.assertEqual(len(self.recorded()), 1)

    def test_bad_names_and_usage_are_refused_before_ssh(self):
        for args in (('dockerhost', 'x;reboot'), ('dockerhost', '$(id)'),
                     ('dockerhost', 'a b'), ('dockerhost', 'devcarone-'),
                     ('dockerhost',), ('--proxy', 'dockerhost', 'work', 'extra')):
            with self.subTest(args=args):
                result = self.run_client(*args)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self.recorded(), [])

    def test_timestamp_names_reach_the_lookup(self):
        result = self.run_client('dockerhost', 'devcarone-2026-10-04_14-30-06_bpPjL5')
        self.assertIn('No such object', result.stderr)


if __name__ == '__main__':
    unittest.main()
