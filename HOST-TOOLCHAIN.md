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

The first form prompts before updating existing packages, including the
bootstrap tools and any dependency apt would upgrade; declining keeps their versions and still installs new packages
that need no upgrade. It stops on a noninteractive input stream if an update
needs a decision, and it never lets apt remove a package. `--update` updates the managed toolchain without prompting;
use it in a Docker build. The installer configures Codex and Claude Code
Plannotator hooks and shared skill links for the account that invoked `sudo`.
For an image build or a root session, supply `--user NAME` after creating that
non-root account. Without an account, it installs only the system tools and
prints a reminder. To finish user configuration later, run the installer with
`--update --user NAME`.

The installed toolchain includes the Dockerfile's developer apt packages
(including VS Code and Chromium, but not its container session, desktop,
SSH/VNC, logging, or graphics-driver packages), current Node.js LTS with its bundled npm, Codex, GitHub
Copilot, opencode, pi, Claude Code, Firebase CLI, Playwright, tea, gogcli,
Plannotator, and the shared Matt Pocock and Plannotator skills. The installer
does not install Playwright browser downloads; Playwright should use Debian's
Chromium (`channel: 'chrome'`), so the installer links
`/opt/google/chrome/chrome` to the retained custom Chromium command, or to
`/usr/bin/chromium` as the image does; an existing file or link there is kept
with a warning. It does not provision
Forgejo credentials.
The installer-managed `plannotator` command is a launcher for the verified
binary in `/usr/local/lib/devcarone-toolchain/plannotator/`. It supplies the
selected Chromium command as `PLANNOTATOR_BROWSER` and `0` as
`PLANNOTATOR_REMOTE` only when those variables are unset. Explicit values,
including empty values, are preserved. Defaults apply only to Plannotator and
its children, whether invoked from a terminal, hook, or non-login process;
no shell profile is created or edited. An external Plannotator command kept
by the installer is left unchanged and receives no launcher defaults.

On a managed update, the exact stock `/etc/profile.d/devcarone-host-toolchain.sh`
from the old installer is removed after the launcher is installed. A managed
installation record must already exist; customized profiles and symlinks are
preserved with a notice. Those preserved profiles may still set global values;
review or remove them yourself if desired. Existing shells retain previously
exported values until you unset them or start a fresh session.

The installer uses the host's apt configuration for package selection and
repository authentication. It preserves existing sources, mirrors, components,
keyrings, preferences, and `APT_CONFIG`; both legacy `.list` and deb822
`.sources` layouts are supported by apt itself. Installed packages do not
need to remain available from their original repositories. If a required
package is not installed and has no candidate, the installer names it and
stops without rewriting the host's sources. For example, Microsoft's
repository is added only when no `code` package is installed or available.

If `code` is already installed or available through apt, that configuration is
used. Otherwise the installer adds `devcarone-host-vscode.list` in apt's
effective source-parts directory, scoped to the bundled Microsoft key in
`/usr/share/keyrings/devcarone-host-microsoft.gpg`. Existing files are preserved;
a conflict at either of those dedicated paths requires the user to resolve it.
The installer adds no apt pins. Pins left by an older installer are also
preserved and can be reviewed in `/etc/apt/preferences.d/devcarone-host-toolchain`.

Existing host commands are preserved. When a command is already on the
installer's system `PATH`, or its `/usr/local/bin` destination contains an
unmanaged file or symlink, the installer reports it and skips publishing that
command. This also applies to `--update`; unrelated tools continue installing.
Existing custom VS Code and Chromium commands skip their apt packages. Tools
already owned by the installer continue to update normally; modified managed
binaries still require attention instead of being overwritten.

The installer keeps its own verified Node runtime in its private tool directory.
Launchers for managed npm commands select that runtime without replacing or
shadowing the host's Node command. Existing tea and gog commands skip their
downloads/builds. An existing Plannotator command is kept while the shared
skills are still installed through the verified tooling bundle. Preserved
external commands are neither version-checked nor claimed as verified by this
installer. Removing one lets a subsequent `--update` provide that command.

Discovery uses the installer's system `PATH`; it does not inspect individual
users' shell setup or version managers. A user's own command earlier in their
`PATH` (for example `~/.local/bin/claude`) continues to take precedence; run
`command -v claude` as that user to check.

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
resolved npm versions are in the staged project's package lock. Each update
keeps the new and the previously active Node release, npm generation, and
skills generation, so already running agents keep working, and removes older
ones; it leaves directories it did not name alone. If a run is interrupted,
run the installer again with `--update` to complete it.

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
checksum, provenance bundle or attestation response, or unrecognized signer
stops the run. An
unrecognized future signing key requires a reviewed update to this bundle's
trust data; downloading a new key from the same release server would not
authenticate it. A fallback never replaces a newer verified installation.

The npm lifecycle scripts run only after registry signature and available
provenance checks pass, matching the Dockerfile. Those scripts may access the
network themselves; npm's audit does not verify arbitrary downloads made by
package lifecycle scripts. A successful script run verifies package downloads
and installs, but does not substitute for an image build or interactive
X/VNC/SSH/agent check.
