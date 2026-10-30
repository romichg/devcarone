"""Keep the standalone installer aligned with the existing image toolchain."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
DOCKERFILE = (ROOT / "Dockerfile").read_text()
INSTALLER = (ROOT / "install-host-toolchain.sh").read_text()


def words_in_assignment(text, name):
    body = text.split(f"{name}=(", 1)[1].split(")", 1)[0]
    return set(body.split())


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


if __name__ == "__main__":
    unittest.main()
