"""Keep the standalone installer aligned with the image and test its behavior."""
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DOCKERFILE = (ROOT / "Dockerfile").read_text()
INSTALLER = (ROOT / "install-host-toolchain.sh").read_text()


def words_in_assignment(text, name):
    body = text.split(f"{name}=(", 1)[1].split(")", 1)[0]
    return set(body.split())


def installer_value(name):
    return re.search(rf"\b{name}='?([^'\s]+)", INSTALLER).group(1)


class HostToolchainParityTests(unittest.TestCase):
    def test_apt_package_set_matches_dockerfile(self):
        body = DOCKERFILE.split("apt-get -y --no-install-recommends install \\\n", 1)[1]
        body = body.split("&&", 1)[0]
        image_packages = set(re.findall(r"[a-z0-9][a-z0-9+.-]+", body)) | {"code"}
        self.assertEqual(words_in_assignment(INSTALLER, "APT_PACKAGES"), image_packages)

    def test_npm_package_set_matches_dockerfile(self):
        image_packages = set(re.findall(
            r"RUN npm install -g --ignore-scripts ([^\s]+)", DOCKERFILE))
        self.assertEqual(words_in_assignment(INSTALLER, "NPM_PACKAGES"), image_packages)

    def test_node_signers_match_dockerfile(self):
        docker_signers = re.search(r'releasers="(.*?)";', DOCKERFILE, re.S).group(1)
        docker_signers = set(re.findall(r"[A-F0-9]{40}", docker_signers))
        installer_signers = INSTALLER.split("readonly NODE_KEYS='", 1)[1].split("'", 1)[0]
        self.assertEqual(set(installer_signers.split()), docker_signers)

    def test_fallback_versions_match_dockerfile(self):
        for docker_arg, installer_name, prefix in (
            ("TEA_VERSION", "TEA_KNOWN", "v"),
            ("PLANNOTATOR_VERSION", "PLANNOTATOR_KNOWN", ""),
            ("GOGCLI_VERSION", "GOG_KNOWN", ""),
        ):
            image_version = re.search(rf"^ARG {docker_arg}=(\S+)$", DOCKERFILE, re.M).group(1)
            installer_version = re.search(rf"\b{installer_name}=(\S+)", INSTALLER).group(1)
            self.assertEqual(installer_version, prefix + image_version)


# Real utilities the installer may run inside the test root. External effects
# (apt, downloads, signatures, builds, privilege changes) are substitutes.
REAL_COMMANDS = """
    awk basename bash cat chmod cmp cp cut date dirname env find getent grep head
    id install jq ln ls mkdir mktemp mv od python3 readlink rm sed sha256sum sleep
    sort stat tar touch tr true uniq wc xz
""".split()

LOGGED = 'printf "%s\\n" "${0##*/} $*" >> "$DEVCAR_HOST_TOOLCHAIN_TEST_ROOT/commands.log"\n'

SUBSTITUTES = {
    "dpkg": 'echo amd64\n',
    "apt-get": "",
    # Installed versions live in apt/installed/<package>; candidates default to 1.0.
    "dpkg-query": '''
state=$DEVCAR_HOST_TOOLCHAIN_TEST_ROOT/apt/installed/${@: -1}
[[ -f $state ]] || exit 1
case $* in *Status*) echo 'ii ' ;; *) cat "$state" ;; esac
''',
    "apt-cache": '''
package=$2 root=$DEVCAR_HOST_TOOLCHAIN_TEST_ROOT/apt
candidate=$(cat "$root/candidate/$package" 2>/dev/null || echo 1.0)
installed=$(cat "$root/installed/$package" 2>/dev/null || echo '(none)')
origin=https://deb.debian.org/debian
[[ $package == code ]] && origin=https://packages.microsoft.com/repos/code
printf '%s:\\n  Installed: %s\\n  Candidate: %s\\n  Version table:\\n' \\
    "$package" "$installed" "$candidate"
for version in $(printf '%s\\n%s\\n' "$candidate" "$installed" | grep -v none | sort -u); do
    marker='    '
    [[ $version == "$installed" ]] && marker=' ***'
    printf '%s %s 500\\n        500 %s trixie/main amd64 Packages\\n' "$marker" "$version" "$origin"
done
''',
    # Key files hold their fingerprints, one per line; signatures hold the signer.
    "gpg": '''
case " $* " in
    *" --show-keys "*)
        while IFS= read -r key; do printf 'pub:u:255:22:X:0:::u:::scSC:\\nfpr:::::::::%s:\\n' "$key"; done < "${@: -1}" ;;
    *" --verify "*)
        signature=${@: -2:1} signer=$(cat "${@: -2:1}")
        [[ $signer == BAD ]] && exit 1
        echo "[GNUPG:] VALIDSIG 0 0 0 0 0 0 0 0 0 $signer" ;;
esac
''',
    # Responses are files named by the SHA-256 of the requested URL.
    "curl": '''
output= url=
while (($#)); do
    case $1 in -o) output=$2; shift ;; --retry) shift ;; http*) url=$1 ;; esac
    shift
done
response=$DEVCAR_HOST_TOOLCHAIN_TEST_ROOT/responses/$(printf %s "$url" | sha256sum | cut -c1-64)
[[ -f $response ]] || exit 22
if [[ -n $output ]]; then cp -- "$response" "$output"; else cat -- "$response"; fi
''',
    "go": 'printf "#!/bin/sh\\necho gog\\n" > "$GOBIN/gog"\nchmod 755 "$GOBIN/gog"\n',
    "gosu": 'shift\nexec "$@"\n',
}

FAKE_NPM = '''#!/bin/sh
printf '%s\\n' "npm $*" >> "$DEVCAR_HOST_TOOLCHAIN_TEST_ROOT/commands.log"
prefix=
while [ $# -gt 0 ]; do [ "$1" = --prefix ] && prefix=$2; shift; done
if [ -n "$prefix" ] && [ ! -d "$prefix/node_modules/.bin" ]; then
    mkdir -p "$prefix/node_modules/.bin"
    for name in codex copilot opencode pi claude firebase playwright; do
        printf '#!/bin/sh\\n' > "$prefix/node_modules/.bin/$name"
        chmod 755 "$prefix/node_modules/.bin/$name"
    done
fi
'''

FAKE_TOOLING = '''#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "install-tooling.sh $*" >> "$DEVCAR_HOST_TOOLCHAIN_TEST_ROOT/commands.log"
mkdir -p "$3/opt/devcar/tooling/plannotator/plannotator-review" "$3/usr/local/bin"
echo plannotator/plannotator-review > "$3/opt/devcar/tooling/skills.list"
touch "$3/opt/devcar/tooling/plannotator/plannotator-review/SKILL.md"
printf '#!/bin/sh\\necho plannotator\\n' > "$3/usr/local/bin/plannotator"
'''

DEBIAN_SOURCES = """Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp

Types: deb
URIs: https://security.debian.org/debian-security
Suites: trixie-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp
"""


class InstallerRoot:
    """A marked temporary system root with substitute commands and responses."""

    node_version = "24.0.0"

    def __init__(self, directory):
        self.root = Path(directory)
        self.bundle = self.root / "bundle"
        (self.root / ".devcarone-host-toolchain-test-root").touch()
        for path in ("test-bin", "usr/bin", "tmp", "home", "responses", "apt/installed",
                     "apt/candidate", "etc/apt/sources.list.d", "etc/apt/preferences.d",
                     "etc/profile.d", "usr/share/keyrings", "bundle/keys"):
            (self.root / path).mkdir(parents=True, exist_ok=True)
        self._install_commands()
        self._install_bundle()
        (self.root / "etc/os-release").write_text("ID=debian\nVERSION_CODENAME=trixie\n")
        self.write("etc/apt/sources.list.d/debian.sources", DEBIAN_SOURCES)
        self.write("usr/share/keyrings/debian-archive-keyring.pgp",
                   installer_value("DEBIAN_KEYS") + "\n")
        self._respond_to_known_releases()

    def write(self, relative, content, mode=0o644):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content.encode() if isinstance(content, str) else content)
        path.chmod(mode)
        return path

    def respond(self, url, content):
        self.write(f"responses/{hashlib.sha256(url.encode()).hexdigest()}", content)

    def _install_commands(self):
        for name in REAL_COMMANDS:
            real = shutil.which(name, path="/usr/bin:/bin")
            if real is None:
                raise unittest.SkipTest(f"{name} is required for installer tests")
            (self.root / "test-bin" / name).symlink_to(real)
        for name, body in SUBSTITUTES.items():
            self.write(f"test-bin/{name}", "#!/usr/bin/env bash\n" + LOGGED + body, 0o755)

    def _install_bundle(self):
        for name in ("install-host-toolchain.sh", "link-skills.sh", "configure-codex.py",
                     "configure-claude.py", "go-ipv4-proxy.py"):
            shutil.copy2(ROOT / name, self.bundle / name)
        self.write("bundle/install-tooling.sh", FAKE_TOOLING, 0o755)
        self.write("bundle/microsoft.asc.gpg", installer_value("MICROSOFT_KEY") + "\n")
        self.write("bundle/keys/nodejs-release.asc", installer_value("NODE_KEYS") + "\n")
        self.write("bundle/keys/teabot.asc", installer_value("TEA_KEY") + "\n")

    def _respond_to_known_releases(self):
        node_url = f"https://nodejs.org/dist/v{self.node_version}"
        tarball_name = f"node-v{self.node_version}-linux-x64.tar.xz"
        tarball = self.node_archive()
        self.respond("https://nodejs.org/dist/index.json",
                     json.dumps([{"version": f"v{self.node_version}", "lts": "Test"}]))
        self.respond(f"{node_url}/{tarball_name}", tarball)
        self.respond(f"{node_url}/SHASUMS256.txt",
                     f"{hashlib.sha256(tarball).hexdigest()}  {tarball_name}\n")
        self.respond(f"{node_url}/SHASUMS256.txt.sig", installer_value("NODE_KEYS"))

        tea = installer_value("TEA_KNOWN")
        tea_asset = f"tea-{tea[1:]}-linux-amd64"
        tea_binary = b"#!/bin/sh\necho tea\n"
        tea_url = f"https://gitea.com/gitea/tea/releases/download/{tea}"
        self.respond(f"{tea_url}/{tea_asset}", tea_binary)
        self.respond(f"{tea_url}/checksums.txt",
                     f"{hashlib.sha256(tea_binary).hexdigest()}  {tea_asset}\n")
        self.respond(f"{tea_url}/checksums.txt.sig", installer_value("TEA_KEY"))
        self.respond("https://api.github.com/repos/mattpocock/skills/commits/main",
                     json.dumps({"sha": "a" * 40}))

    def node_archive(self, owner=0):
        files = {"bin/node": "#!/bin/sh\n", "bin/npm": FAKE_NPM, "bin/npx": "#!/bin/sh\n"}
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:xz") as archive:
            for name, content in files.items():
                data = content.encode()
                info = tarfile.TarInfo(f"node-v{self.node_version}-linux-x64/{name}")
                info.size, info.mode, info.uid, info.gid = len(data), 0o755, owner, owner
                archive.addfile(info, io.BytesIO(data))
        return buffer.getvalue()

    def run(self, *arguments, input=""):
        environment = {
            "PATH": str(self.root / "test-bin"),
            "HOME": str(self.root / "home"),
            "TMPDIR": str(self.root / "tmp"),
            "DEVCAR_HOST_TOOLCHAIN_TEST_ROOT": str(self.root),
        }
        return subprocess.run(
            [str(self.root / "test-bin/bash"), str(self.bundle / "install-host-toolchain.sh"),
             *arguments],
            env=environment, input=input, capture_output=True, text=True, timeout=60)

    def commands(self):
        log = self.root / "commands.log"
        return log.read_text().splitlines() if log.exists() else []


class HostInstallerBehaviorTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.system = InstallerRoot(directory.name)

    def assertSucceeded(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_fresh_install_activates_verified_tools_inside_test_root(self):
        result = self.system.run()

        self.assertSucceeded(result)
        root = self.system.root
        tool_dir = root / "usr/local/lib/devcarone-toolchain"
        self.assertEqual(os.readlink(root / "usr/local/bin/node"),
                         f"{tool_dir}/current-node/bin/node")
        self.assertEqual(os.readlink(root / "usr/local/bin/claude"),
                         f"{tool_dir}/current-npm/node_modules/.bin/claude")
        for tool in ("tea", "gog", "plannotator"):
            self.assertTrue((root / f"usr/local/bin/{tool}").is_file(), tool)
        state = root / "var/lib/devcarone-host-toolchain"
        self.assertEqual((state / "node-version").read_text(), f"{self.system.node_version}\n")
        self.assertEqual((state / "tea.version").read_text(),
                         installer_value("TEA_KNOWN") + "\n")
        self.assertTrue(os.path.islink(root / "opt/devcar/tooling"))
        self.assertIn("Components: main contrib non-free non-free-firmware",
                      (root / "etc/apt/sources.list.d/debian.sources").read_text())
        self.assertTrue((root / "etc/apt/sources.list.d/vscode.list").is_file())
        self.assertTrue((root / "etc/profile.d/devcarone-host-toolchain.sh").is_file())
        install = [line for line in self.system.commands()
                   if line.startswith("apt-get -y --no-install-recommends install sudo")]
        self.assertEqual(len(install), 1)
        self.assertIn(" code", install[0])
        self.assertIn("System tools installed.", result.stdout)
        self.assertEqual(list((root / "tmp").iterdir()), [])

    def test_unmarked_test_root_is_refused(self):
        (self.system.root / ".devcarone-host-toolchain-test-root").unlink()

        result = self.system.run()

        self.assertEqual(result.returncode, 2)
        self.assertIn("must be absolute and marked", result.stderr)
        self.assertEqual(self.system.commands(), [])

    @unittest.skipIf(os.geteuid() == 0, "requires a non-root test account")
    def test_without_test_root_installer_requires_root(self):
        result = subprocess.run(
            ["bash", str(ROOT / "install-host-toolchain.sh")],
            env={"PATH": "/usr/bin:/bin"}, capture_output=True, text=True, timeout=30)

        self.assertEqual(result.returncode, 1)
        self.assertIn("Run as root", result.stderr)


if __name__ == "__main__":
    unittest.main()
