# Host toolchain installer

`install-host-toolchain.sh` installs the developer tools from this repository's
Dockerfile onto a Debian Trixie amd64 machine or into a Debian Trixie amd64
image. It does not set up devcarone's container account, launcher, SSH/VNC
session, or desktop startup. Run it from a checkout or copy of this entire
`public/` directory: the adjacent keys and tooling scripts are part of its
trust root.

```sh
sudo ./install-host-toolchain.sh
sudo ./install-host-toolchain.sh --update
```

The first form prompts before updating existing packages installed by the
same trusted source. It stops on a noninteractive input stream if an update
needs a decision. `--update` updates the managed toolchain without prompting;
use it in a Docker build. The installer configures Codex and Claude Code
Plannotator hooks and shared skill links for the account that invoked `sudo`.
For an image build or a root session, supply `--user NAME` after creating that
non-root account. Without an account, it installs only the system tools and
prints a reminder. To finish user configuration later, run the installer with
`--update --user NAME`.

The installed toolchain includes the Dockerfile's apt packages (including VS
Code and Chromium), current Node.js LTS with its bundled npm, Codex, GitHub
Copilot, opencode, pi, Claude Code, Firebase CLI, Playwright, tea, gogcli,
Plannotator, and the shared Matt Pocock and Plannotator skills. The installer
does not install Playwright browser downloads; Playwright should use Debian's
Chromium (`channel: 'chrome'`). It does not provision Forgejo credentials.
It adds `/etc/profile.d/devcarone-host-toolchain.sh` so login shells launch
Plannotator with Debian Chromium. In another Docker image, also set
`ENV PLANNOTATOR_BROWSER=/usr/bin/chromium PLANNOTATOR_REMOTE=0` for programs
started without a login shell.

The script requires the standard Debian `debian.sources` file and refuses
additional apt sources; `apt modernize-sources` converts a one-line
`sources.list`. Every active stanza must use `deb.debian.org` (trixie,
trixie-updates, or trixie-backports) or `security.debian.org`
(trixie-security), name the Debian archive keyring in `Signed-By`, and use no
other options such as `Trusted`. Apt settings that allow insecure or
unauthenticated repositories, or that move the source lists, stop the run.
These checks finish before apt runs or any apt file changes. The script then
adds any missing `contrib`, `non-free`, and `non-free-firmware` components for
the Intel media driver, keeping existing components, and adds the VS Code
repository with the committed Microsoft key.
An installed apt package is recognized only if its version is available from
one of those Debian suites or the signed Microsoft repository. Debian's
package database does not retain the repository that originally supplied an
installed package, so a matching version cannot prove its history. Existing
Node, npm agent, tea, gogcli, or Plannotator commands without this installer's
ownership record cause the run to stop.

Node's archive is checked against a GPG signed release manifest and the
allowed Node signer fingerprints in the script. It is extracted with root
ownership; a recorded Node release that other accounts can modify is reported,
and `--update` replaces it. npm packages are staged with
lifecycle scripts disabled, checked with `npm audit signatures` against the
public npm registry, then rebuilt and exposed on `PATH`. tea's checksum file
must be signed by the committed Gitea key. Plannotator must carry Sigstore SLSA
provenance for its release workflow. gogcli and its Go dependencies must pass
Go's checksum database. The Matt Pocock skills use the commit fetched from
GitHub's API and Git's object hashes, as in the Dockerfile. All installed
release ownership records live under `/var/lib/devcarone-host-toolchain`;
resolved npm versions are in the staged project's package lock.

For Go downloads, the script starts a temporary authenticated proxy on
`127.0.0.1` that opens IPv4 upstream sockets. Both the Go module proxy and
checksum database remain HTTPS endpoints, and Go still verifies their TLS and
checksum database signatures. The proxy and its temporary credential are
removed when the install command ends. This avoids changing the host's IPv6
settings; Go's `netdns` option selects a resolver implementation, not an IP
address family.

The latest tea, Plannotator, and gogcli releases are attempted first. If
release metadata or the required verifiable artifact is unavailable, the
script warns and tries the Dockerfile's known version. A bad signature,
checksum, provenance bundle, or unrecognized signer stops the run. An
unrecognized future signing key requires a reviewed update to this bundle's
trust data; downloading a new key from the same release server would not
authenticate it. A fallback never replaces a newer verified installation.

The npm lifecycle scripts run only after registry signature and available
provenance checks pass, matching the Dockerfile. Those scripts may access the
network themselves; npm's audit does not verify arbitrary downloads made by
package lifecycle scripts. A successful script run verifies package downloads
and installs, but does not substitute for an image build or interactive
X/VNC/SSH/agent check.
