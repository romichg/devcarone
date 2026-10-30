"""Keep the standalone installer aligned with the image and test its behavior."""
import hashlib
import io
import json
import os
import pty
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
    awk basename bash cat chmod chown cmp cp cut date dirname env find getent grep head
    id install jq ln ls mkdir mktemp mv od python3 readlink rm sed sha256sum sleep
    sort stat touch tr true uniq wc xz
""".split()
# Real utilities whose arguments tests inspect.
LOGGED_REAL_COMMANDS = ("tar",)

LOGGED = 'printf "%s\\n" "${0##*/} $*" >> "$DEVCAR_HOST_TOOLCHAIN_TEST_ROOT/commands.log"\n'

SUBSTITUTES = {
    "dpkg": 'echo amd64\n',
    # Installs or simulates (-s) the requested packages with candidate versions.
    # apt/depends/<package> lists dependencies; apt/removes/<package> lists
    # packages that installing it would remove.
    "apt-get": '''
root=$DEVCAR_HOST_TOOLCHAIN_TEST_ROOT/apt
simulate=0 packages=() seen_install=0
for argument; do
    case $argument in
        -s) simulate=1 ;;
        install) seen_install=1 ;;
        -*) ;;
        *) ((seen_install)) && packages+=("$argument") ;;
    esac
done
((seen_install)) || exit 0
for package in "${packages[@]}"; do
    for name in $package $(cat "$root/depends/$package" 2>/dev/null); do
        candidate=$(cat "$root/candidate/$name" 2>/dev/null || echo 1.0)
        installed=$(cat "$root/installed/$name" 2>/dev/null || true)
        [[ $installed == "$candidate" ]] && continue
        if ((simulate)); then
            if [[ -n $installed ]]; then
                echo "Inst $name [$installed] ($candidate Debian:13 [amd64])"
            else
                echo "Inst $name ($candidate Debian:13 [amd64])"
            fi
        else
            echo "$candidate" > "$root/installed/$name"
        fi
    done
    for name in $(cat "$root/removes/$package" 2>/dev/null); do
        if ((simulate)); then echo "Remv $name [1.0]"; else rm -f "$root/installed/$name"; fi
    done
done
''',
    # Defaults from apt-config dump plus any settings in apt/config.
    "apt-config": '''
printf '%s\\n' 'Dir "/";' 'Dir::Etc "etc/apt/";' 'Dir::Etc::sourcelist "sources.list";' \\
    'Dir::Etc::sourceparts "sources.list.d";' 'APT::Get::AllowUnauthenticated "false";'
cat "$DEVCAR_HOST_TOOLCHAIN_TEST_ROOT/apt/config" 2>/dev/null || true
''',
    # Installed versions live in apt/installed/<package>.
    "dpkg-query": '''
state=$DEVCAR_HOST_TOOLCHAIN_TEST_ROOT/apt/installed/${@: -1}
[[ -f $state ]] || exit 1
case $* in *Status*) echo 'ii ' ;; *) cat "$state" ;; esac
''',
    # Candidates default to 1.0 from suite apt/suite/<package> (default trixie).
    # Like apt, the non-free driver has no candidate until non-free is enabled.
    "apt-cache": '''
package=$2 root=$DEVCAR_HOST_TOOLCHAIN_TEST_ROOT/apt
candidate=$(cat "$root/candidate/$package" 2>/dev/null || echo 1.0)
installed=$(cat "$root/installed/$package" 2>/dev/null || echo '(none)')
suite=$(cat "$root/suite/$package" 2>/dev/null || echo trixie)
origin=https://deb.debian.org/debian
if [[ $package == code ]]; then origin=https://packages.microsoft.com/repos/code suite=stable; fi
if [[ $package == intel-media-va-driver-non-free ]] && ! grep -Eq \\
    '^Components:.* non-free( |$)' "$DEVCAR_HOST_TOOLCHAIN_TEST_ROOT/etc/apt/sources.list.d/debian.sources"; then
    candidate='(none)'
fi
printf '%s:\\n  Installed: %s\\n  Candidate: %s\\n  Version table:\\n' \\
    "$package" "$installed" "$candidate"
for version in $(printf '%s\\n%s\\n' "$candidate" "$installed" | grep -v none | sort -u); do
    marker='    '
    [[ $version == "$installed" ]] && marker=' ***'
    printf '%s %s 500\\n        500 %s %s/main amd64 Packages\\n' "$marker" "$version" "$origin" "$suite"
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
    node_archive_mode = 0o755

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
        for name in LOGGED_REAL_COMMANDS:
            real = shutil.which(name, path="/usr/bin:/bin")
            self.write(f"test-bin/{name}",
                       f'#!/usr/bin/env bash\n{LOGGED}exec {real} "$@"\n', 0o755)
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
        tarball = self.node_archive(mode=self.node_archive_mode)
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

    def node_archive(self, owner=1001, mode=0o755):
        files = {"bin/node": "#!/bin/sh\n", "bin/npm": FAKE_NPM, "bin/npx": "#!/bin/sh\n"}
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:xz") as archive:
            for name, content in files.items():
                data = content.encode()
                info = tarfile.TarInfo(f"node-v{self.node_version}-linux-x64/{name}")
                info.size, info.mode, info.uid, info.gid = len(data), mode, owner, owner
                archive.addfile(info, io.BytesIO(data))
        return buffer.getvalue()

    def run(self, *arguments, input="", terminal=None):
        environment = {
            "PATH": str(self.root / "test-bin"),
            "HOME": str(self.root / "home"),
            "TMPDIR": str(self.root / "tmp"),
            "DEVCAR_HOST_TOOLCHAIN_TEST_ROOT": str(self.root),
        }
        command = [str(self.root / "test-bin/bash"),
                   str(self.bundle / "install-host-toolchain.sh"), *arguments]
        if terminal is None:
            return subprocess.run(command, env=environment, input=input,
                                  capture_output=True, text=True, timeout=60)
        # Answer prompts through a pseudo-terminal; "\x04" ends input.
        controller, terminal_fd = pty.openpty()
        try:
            os.write(controller, terminal.encode())
            return subprocess.run(command, env=environment, stdin=terminal_fd,
                                  capture_output=True, text=True, timeout=60)
        finally:
            os.close(controller)
            os.close(terminal_fd)

    def installed(self, package, version=None):
        path = self.root / "apt/installed" / package
        if version is not None:
            self.write(f"apt/installed/{package}", version + "\n")
        return path.read_text().strip() if path.exists() else None

    def apt_installs(self):
        return [line.split(" install ", 1)[1].split()
                for line in self.commands() if line.startswith("apt-get -y ")]

    def commands(self):
        log = self.root / "commands.log"
        return log.read_text().splitlines() if log.exists() else []


ARCHIVE_STANZA = """Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie trixie-updates
Components: {components}
Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp
"""


class HostInstallerSourceTests(unittest.TestCase):
    """Apt configuration is validated completely before apt runs or anything changes."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.system = InstallerRoot(directory.name)
        self.sources = self.system.root / "etc/apt/sources.list.d/debian.sources"

    def use_sources(self, text):
        self.sources.write_text(text)

    def assertRefused(self, message):
        before = self.sources.read_text()
        result = self.system.run()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)
        self.assertFalse([line for line in self.system.commands() if line.startswith("apt-get")])
        self.assertEqual(self.sources.read_text(), before)
        self.assertFalse((self.system.root / "etc/apt/preferences.d/devcarone-host-toolchain").exists())

    def test_additional_uri_in_an_allowed_stanza_is_refused(self):
        self.use_sources(DEBIAN_SOURCES.replace(
            "URIs: https://deb.debian.org/debian",
            "URIs: https://deb.debian.org/debian https://packages.example.com/debian", 1))
        self.assertRefused("unexpected repository URI https://packages.example.com/debian")

    def test_additional_stanza_with_another_repository_is_refused(self):
        self.use_sources(DEBIAN_SOURCES + "\n" + ARCHIVE_STANZA.format(components="main").replace(
            "https://deb.debian.org/debian", "https://mirror.example.com/debian"))
        self.assertRefused("unexpected repository URI https://mirror.example.com/debian")

    def test_trust_and_authentication_options_are_refused(self):
        for option in ("Trusted: yes", "Allow-Insecure: yes", "Allow-Weak: yes"):
            with self.subTest(option=option):
                self.use_sources(DEBIAN_SOURCES.replace(
                    "Components: main\n", f"Components: main\n{option}\n", 1))
                self.assertRefused("unsupported option " + option.split(":")[0].lower())

    def test_stanza_without_debian_keyring_scope_is_refused(self):
        for replacement in ("", "Signed-By: /etc/apt/trusted.gpg.d/other.gpg\n",
                            "Signed-By:\n -----BEGIN PGP PUBLIC KEY BLOCK-----\n"):
            with self.subTest(replacement=replacement):
                self.use_sources(DEBIAN_SOURCES.replace(
                    "Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp\n", replacement, 1))
                self.assertRefused("Signed-By must name the Debian archive keyring")

    def test_unsupported_suites_are_refused(self):
        for old, new in (("Suites: trixie trixie-updates", "Suites: trixie sid"),
                         ("Suites: trixie trixie-updates", "Suites: trixie-security"),
                         ("Suites: trixie-security", "Suites: trixie")):
            with self.subTest(suites=new):
                self.use_sources(DEBIAN_SOURCES.replace(old, new, 1))
                self.assertRefused("unexpected suite")

    def test_apt_settings_that_weaken_authentication_are_refused(self):
        for setting in ('Acquire::AllowInsecureRepositories "true";',
                        'Binary::apt-get::APT::Get::AllowUnauthenticated "1";',
                        'Acquire::AllowDowngradeToInsecureRepositories "yes";',
                        'Dir::Etc::sourceparts "/srv/apt/sources.d";'):
            with self.subTest(setting=setting):
                self.system.write("apt/config", setting + "\n")
                self.assertRefused(f"Apt setting {setting.split()[0]} needs review")

    def test_disabled_stanza_and_supported_suites_are_accepted(self):
        disabled = ARCHIVE_STANZA.format(components="main").replace(
            "https://deb.debian.org/debian", "https://mirror.example.com/debian") + "Enabled: no\n"
        self.use_sources(DEBIAN_SOURCES.replace(
            "Types: deb\n", "# Debian archive\nTypes: deb deb-src\n", 1).replace(
            "trixie trixie-updates", "trixie trixie-updates trixie-backports", 1) + "\n" + disabled)

        result = self.system.run()

        self.assertEqual(result.returncode, 0, result.stderr)
        text = self.sources.read_text()
        self.assertIn("# Debian archive\nTypes: deb deb-src\n", text)
        self.assertIn("Components: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.pgp\n"
                      "Enabled: no\n", text)

    def test_installed_package_from_unsupported_suite_is_refused(self):
        self.system.write("apt/installed/vim", "1.0\n")
        self.system.write("apt/suite/vim", "sid\n")

        result = self.system.run()

        self.assertEqual(result.returncode, 1)
        self.assertIn("vim 1.0 is not attributable to its expected apt repository", result.stderr)

    def test_required_components_are_added_to_each_active_stanza_once(self):
        cases = {
            "main": "main contrib non-free non-free-firmware",
            "main non-free-firmware": "main non-free-firmware contrib non-free",
            "main contrib": "main contrib non-free non-free-firmware",
            "main contrib non-free non-free-firmware": "main contrib non-free non-free-firmware",
            "non-free-firmware main contrib non-free": "non-free-firmware main contrib non-free",
        }
        for existing, expected in cases.items():
            with self.subTest(existing=existing):
                self.use_sources(DEBIAN_SOURCES.replace("Components: main", f"Components: {existing}"))
                before = self.sources.stat()
                self.sources.chmod(0o640)

                result = self.system.run("--update")

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.sources.read_text(), DEBIAN_SOURCES.replace(
                    "Components: main", f"Components: {expected}"))
                self.assertEqual(self.sources.stat().st_mode & 0o777, 0o640)
                if existing == expected:
                    self.assertEqual(self.sources.stat().st_ino, before.st_ino)

    def test_enabling_non_free_makes_the_driver_candidate_available(self):
        result = self.system.run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(" intel-media-va-driver-non-free ", next(
            line for line in self.system.commands()
            if line.startswith("apt-get -y --no-install-recommends install sudo")))


class HostInstallerAptConsentTests(unittest.TestCase):
    """Existing apt packages change only with --update or the user's consent."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.system = InstallerRoot(directory.name)

    def outdated_bootstrap_package(self):
        self.system.installed("curl", "0.9")

    def test_up_to_date_bootstrap_package_is_not_requested(self):
        self.system.installed("curl", "1.0")

        result = self.system.run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.system.apt_installs()[0], ["ca-certificates", "gnupg", "jq", "xz-utils"])
        self.assertTrue(all("curl" not in install for install in self.system.apt_installs()))

    def test_unattended_run_stops_before_upgrading_bootstrap_package(self):
        self.outdated_bootstrap_package()

        result = self.system.run()

        self.assertEqual(result.returncode, 1)
        self.assertIn("rerun with --update: curl", result.stderr)
        self.assertEqual(self.system.apt_installs(), [])
        self.assertEqual(self.system.installed("curl"), "0.9")

    def test_update_option_upgrades_existing_packages(self):
        self.outdated_bootstrap_package()

        result = self.system.run("--update")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("curl", self.system.apt_installs()[0])
        self.assertEqual(self.system.installed("curl"), "1.0")

    def test_declining_keeps_existing_versions_and_installs_new_packages(self):
        self.outdated_bootstrap_package()

        result = self.system.run(terminal="n\n")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.count("Update curl from their signed apt repositories?"), 1)
        self.assertEqual(self.system.installed("curl"), "0.9")
        self.assertEqual(self.system.apt_installs()[0], ["ca-certificates", "gnupg", "jq", "xz-utils"])
        self.assertIn("sudo", self.system.apt_installs()[1])
        self.assertNotIn("curl", self.system.apt_installs()[1])

    def test_accepting_upgrades_existing_packages(self):
        self.outdated_bootstrap_package()

        result = self.system.run(terminal="y\n")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.system.installed("curl"), "1.0")

    def test_end_of_input_at_prompt_is_a_refusal(self):
        self.outdated_bootstrap_package()

        result = self.system.run(terminal="\x04")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No answer; treating it as no.", result.stderr)
        self.assertEqual(self.system.installed("curl"), "0.9")

    def test_dependency_upgrade_of_new_package_needs_consent(self):
        self.system.write("apt/depends/vim", "libvim-runtime\n")
        self.system.installed("libvim-runtime", "0.9")

        unattended = self.system.run()
        self.assertEqual(unattended.returncode, 1)
        self.assertIn("rerun with --update: libvim-runtime", unattended.stderr)

        declined = self.system.run(terminal="n\n")
        self.assertEqual(declined.returncode, 1)
        self.assertIn("requires updating libvim-runtime; rerun with --update", declined.stderr)
        self.assertEqual(self.system.installed("libvim-runtime"), "0.9")

        updated = self.system.run("--update")
        self.assertEqual(updated.returncode, 0, updated.stderr)
        self.assertEqual(self.system.installed("libvim-runtime"), "1.0")

    def test_installation_that_would_remove_a_package_is_refused(self):
        self.system.write("apt/removes/vim", "vim-tiny\n")
        self.system.installed("vim-tiny", "1.0")

        result = self.system.run("--update")

        self.assertEqual(result.returncode, 1)
        self.assertIn("would remove vim-tiny", result.stderr)
        self.assertEqual(self.system.installed("vim-tiny"), "1.0")


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

    def node_release(self):
        return (self.system.root / "usr/local/lib/devcarone-toolchain/node"
                / self.system.node_version)

    def test_node_archive_owner_and_writable_modes_are_not_kept(self):
        self.system.node_archive_mode = 0o777
        self.system._respond_to_known_releases()

        self.assertSucceeded(self.system.run())

        extraction = [line for line in self.system.commands() if line.startswith("tar ")]
        self.assertEqual(len(extraction), 1)
        self.assertIn("--no-same-owner --no-same-permissions", extraction[0])
        node = self.node_release() / "bin/node"
        self.assertEqual(node.stat().st_uid, os.getuid())
        self.assertEqual(node.stat().st_mode & 0o022, 0)

    def test_update_replaces_recorded_release_that_others_can_modify(self):
        self.assertSucceeded(self.system.run())
        release = self.node_release()
        (release / "bin/node").chmod(0o777)
        (release / "planted").write_text("")

        result = self.system.run("--update")

        self.assertSucceeded(result)
        self.assertIn("Replacing Node", result.stderr)
        self.assertFalse((release / "planted").exists())
        self.assertEqual((release / "bin/node").stat().st_mode & 0o022, 0)
        self.assertEqual(sorted(path.name for path in release.parent.iterdir()),
                         [self.system.node_version])
        self.assertEqual(os.readlink(self.system.root / "usr/local/bin/node"),
                         f"{release.parent.parent}/current-node/bin/node")

    def test_recorded_release_that_others_can_modify_is_reported(self):
        self.assertSucceeded(self.system.run())
        (self.node_release() / "bin/node").chmod(0o777)

        result = self.system.run()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rerun with --update to replace it", result.stderr)

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
