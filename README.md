# devcarone v1

A Debian Trixie developer container with AI coding agents (Codex, Claude Code,
opencode, Copilot, pi), VS Code, Chromium, Playwright, and a TeX/pandoc
toolchain, plus a Linux host launcher. Everything needed to build and run it is
in this directory. Sessions open in a terminal on the host's X display or on a
VNC desktop reached over SSH, with per-session copies of your configuration.

## Status and trust boundary

This is an experimental personal development environment for x86_64 Linux
hosts with Docker, sudo/OverlayFS, and an Intel render device at
`/dev/dri/renderD128`. See "Build" for host requirements and "Verification"
for checks to run on your own host.

Run trusted projects and tools here. Programs and AI agents in the container
can modify the mounted workspace and read mounted configuration and credentials.
X mode connects to the host display. This container is not a security boundary
for hostile code or untrusted agents.

## Agent skills and Plannotator

Codex, Claude Code, and opencode share one skill collection, downloaded during
the image build into `/opt/devcar/tooling`. At every container start,
`entrypoint.sh` runs `link-skills.sh` to link each skill into:

- `/etc/codex/skills`, the documented
  [Codex admin skill location](https://learn.chatgpt.com/docs/build-skills);
- `~/.claude/skills`, which
  [Claude Code](https://code.claude.com/docs/en/skills) and
  [opencode](https://opencode.ai/docs/skills/) both read.

The links point into the image, so the sources are never copied into a mounted
home directory and image upgrades take effect on the next launch. A skill
directory or link of your own with the same name is kept, with a warning, and
links to skills no longer in the image are removed. Launch with
`DEVCAR_SKILLS=0` to remove the image's links for all three agents and leave
your own skills alone.

- [Matt Pocock's skills](https://github.com/mattpocock/skills): the skills
  listed in the Claude Code `plugin.json` on his `main` branch at build time,
  which is what `/plugin install` gives Claude Code users. His in-progress and miscellaneous skills are not linked. In
  Claude Code they are ordinary personal skills, so the names have no plugin
  prefix (`/tdd`, not `/mattpocock-skills:tdd`).
- [Plannotator](https://github.com/backnotprop/plannotator): version `v0.27.21`,
  installed at `/usr/local/bin/plannotator` after verifying its Sigstore build
  provenance (see "Download verification").
  Includes `plannotator`, `plannotator-review`, `plannotator-annotate`, and
  `plannotator-last` skills.

The build reads the branch's latest commit from the GitHub API, so Docker
reruns the tooling step (one of the last, quick layers) only when Matt publishes
a change; a plain `docker build` picks it up. Set `--build-arg
MATT_POCOCK_REF=<commit or tag>` to pin a version instead. The request is
anonymous; if GitHub's hourly API limit refuses it, wait or build with a pinned
commit. Plannotator stays pinned to `PLANNOTATOR_VERSION`, because its
provenance must name the release workflow run for that exact tag. The
build fails if a listed skill is missing or two skills share a name.
`/opt/devcar/tooling/versions.txt` records the installed commit and version,
and `/opt/devcar/tooling/skills.list` the linked skills.

Plannotator's [Codex integration](https://github.com/backnotprop/plannotator/blob/v0.27.21/apps/codex/README.md)
uses a `Stop` hook for plan review. After the configuration overlay is mounted,
`entrypoint.sh` runs `configure-codex.py` as the container user. It enables
`features.hooks` in `$CODEX_HOME/config.toml` (default `~/.codex/config.toml`) and
merges the Plannotator hook into `hooks.json`, or existing inline TOML hooks.
It preserves unrelated settings, comments in TOML, and custom hooks; repeating
startup does not add duplicates. Invalid configuration stops startup with an
error rather than replacing the files. This small configuration is the only
part that needs to be in `.codex`; startup downloads nothing.

In Codex, use `/skills` to inspect the collection, then try:

```text
$setup-matt-pocock-skills
$plannotator-review
$plannotator-annotate README.md
```

In Claude Code, `/` lists the same skills (`/setup-matt-pocock-skills`,
`/plannotator-review`).

Plannotator's [Claude Code plugin](https://github.com/backnotprop/plannotator/tree/v0.27.21/apps/hook)
is not installed; `entrypoint.sh` instead runs `configure-claude.py`, which
merges the plugin's two hooks into `~/.claude/settings.json` (or
`$CLAUDE_CONFIG_DIR`): a `PermissionRequest` hook for `ExitPlanMode` that sends
each plan to Plannotator for review, and a `PreToolUse` hook for `EnterPlanMode`
that runs `plannotator improve-context`. It follows the same rules as the Codex
step: unrelated settings and hooks are kept, an existing Plannotator hook for
the same event is not duplicated, and invalid JSON stops startup without
changing the file. If you also install the Plannotator plugin yourself, remove
these hooks to avoid reviewing each plan twice.

Run Matt's setup skill once per project when you want to configure its workflows.
For automatic plan review, open `/hooks` and trust the Plannotator hook if Codex
requests it. Codex requires review of new or changed non-managed hooks; see
[hook trust](https://learn.chatgpt.com/docs/hooks). The integration does not
bypass that review. Hook trust follows your existing session configuration
overlay, so a fresh overlay may request it again unless your master Codex
configuration already contains the matching trust record.

Plannotator opens Chromium **inside the container**, on your X display or VNC
desktop. The image sets `PLANNOTATOR_BROWSER=/usr/bin/chromium` and
`PLANNOTATOR_REMOTE=0`; no additional host port or SSH tunnel is needed for this
desktop workflow. Plans and preferences use Plannotator's default
`~/.plannotator` directory, outside `.codex`. That directory is not mounted by
the launcher, so its contents disappear when the container is removed. Export
anything you want to keep into the mounted `~/src` workspace.

## gogcli

[gogcli](https://github.com/openclaw/gogcli) `v0.43.0` (override
`GOGCLI_VERSION`) is built from source at image build time with `go install`
and installed as `/usr/local/bin/gog`, on PATH in both X and VNC terminals.
Startup does not download anything. Homebrew is not installed: gogcli's Linux
releases carry no signatures, while Go's checksum database verifies the
source (see "Download verification").

The launcher mounts `$MAINDIR/gogcli` at `~/.gogcli` and sets `GOG_HOME` to
that location. This auth directory is shared across launches, outside the
per-session overlay, so imported OAuth credentials and encrypted tokens survive
container removal. New directories are created with mode `0700`; existing
directory permissions are preserved. It must be writable by the build account.

On the host, select your account before launching:

```sh
export GOG_ACCOUNT=you@example.com
/path/to/devcarone/devcarone
```

With the default file keyring, the launcher prompts without echo for
`GOG_KEYRING_PASSWORD` if an account is set and the password is missing.
Noninteractive launches must supply it through the host environment (for
example, from a secret manager). The password is forwarded by environment name,
not placed in Docker command arguments. With no account set, launch needs no
password; you can configure authentication later in the container terminal.

For initial setup, follow the upstream [authentication quickstart](https://github.com/openclaw/gogcli/blob/main/docs/quickstart.md).
Import your Desktop OAuth client JSON and authorize the services you need from
the container terminal, for example:

```sh
gog auth credentials set /path/to/client.json
gog auth add "$GOG_ACCOUNT" --services gmail,calendar,drive --manual
gog auth doctor --check --no-input
```

Make the JSON temporarily available outside this repository's build context.
Keep credentials, tokens, and passwords out of Git and the image. Use the same
keyring password on subsequent launches. The forwarded environment is available
to the X/VNC desktop; separate SSH login shells do not automatically inherit it.

## Forgejo

Agents and terminals in the container can push to Forgejo and manage issues and
pull requests with one personal access token. Put the token alone in
`$MAINDIR/forgejo/token` (override with `FORGEJO_TOKEN_FILE`):

```sh
install -d -m 700 "$MAINDIR/forgejo"
(umask 077; cat > "$MAINDIR/forgejo/token")   # paste, then Ctrl-D
```

Set `FORGEJO_URL` (for example `https://forgejo.example.com:3000`) and
`FORGEJO_USER`, usually in `devcarone.env` (see "Configuration"); a token
without them stops the launch.

Without that file, launches have no Forgejo access. With it, the launcher mounts
the file read-only in X and VNC modes and startup configures:

- a system git credential helper scoped to `FORGEJO_URL`, so `git push`/`fetch`
  over HTTPS use `FORGEJO_USER` and the token. Other hosts are unaffected.
- [tea](https://gitea.com/gitea/tea) `v0.16.0` (GPG-verified at build time;
  override `TEA_VERSION`) with a default `forgejo` login, for example
  `tea issues create --title ...` or `tea pulls create`. Inside a clone, tea
  selects the repository from its remote.

The token is never written to the image, overlay, or Git configuration; the
tea login is a mode `0600` file under `/run/devcar/tea`, outside the mounted
`~/.config`, and disappears with the container. Any process running as the
container user, including Claude, Codex, and opencode, can read and use the token.
Limit what it can do in Forgejo instead:

- Create it under Settings → Applications with only `write:repository` and
  `write:issue`, restricted to **specific repositories** when your Forgejo
  version offers that option. Such tokens
  cannot perform repository administration.
- Token scopes cannot exclude branches. Protect `main` (Settings → Branches),
  disable direct pushes, and require pull requests. Branch protection applies
  to the account, so it also stops your own direct pushes with any credential.
- Rotate the token by replacing the file; running containers keep the old
  tea login until relaunch, while git reads the file on each use.

## Build

On the Linux Docker host, build for the account that will launch devcar. Copy
the whole line:

```sh
docker build -t devcarone:v1 --build-arg UID=$(id -u) --build-arg GID=$(id -g) --build-arg USER=$(id -un) .
```

Add other options right after `docker build`, keeping the rest of the line as
is. For example, to rebuild every layer:

```sh
docker build --no-cache -t devcarone:v1 --build-arg UID=$(id -u) --build-arg GID=$(id -g) --build-arg USER=$(id -un) .
```

Other options:

- `--network=NETWORK` if your Docker installation needs a particular network
  for internet access.
- `--build-arg TZ=Europe/Amsterdam` (for example) to change the time zone from
  the default `America/New_York`.

The first build step rejects a malformed `UID`, `GID`, or `USER` within
seconds. The npm agents and Debian packages are installed at their current
releases, so this is not a reproducible build; see "Download verification" for
what is pinned and checked.

Host requirements: Bash, Docker, sudo/mount with OverlayFS support, `setsid`
(util-linux), root access to the Docker daemon for session cleanup, and the
existing `/dev/dri/renderD128` GPU device. X mode also requires `xauth` and a
working host X display. Audio is forwarded when `/run/user/$(id -u)/pulse` exists.

To install the same developer tools directly on a Debian Trixie amd64 machine
or in another Debian image, without the container, use
`install-host-toolchain.sh`; see [HOST-TOOLCHAIN.md](HOST-TOOLCHAIN.md).

## Download verification

The build checks each download against a trust root recorded in this
repository, not only against a checksum from the same server:

| Download | Check | Trust root |
| --- | --- | --- |
| Base image | Pinned `debian:trixie-slim@sha256:…` digest | The digest in the `Dockerfile` |
| Debian packages | apt signature checks; the build fails if the archive keyring holds a key outside the listed fingerprints | Debian 11–13 archive, security, and release key fingerprints in the `Dockerfile` |
| VS Code | apt signature checks | `microsoft.asc.gpg` (`BC52 8686 B50D 79E3 39D3 721C EB3E 94AD BE12 29CF`) |
| Node.js | GPG-signed `SHASUMS256.txt`, signer must be a listed releaser | `keys/nodejs-release.asc` and the releaser fingerprints in the `Dockerfile`, from Node's README |
| tea | GPG-signed `checksums.txt` | `keys/teabot.asc`, Gitea's Teabot key `7C9E 6815 2594 6888 62D6 2AF6 2D9A E806 EC15 92E2` |
| Plannotator | Sigstore SLSA provenance via `cosign` | The release workflow and tag in `install-tooling.sh`, Sigstore's public root |
| gogcli and its Go toolchain | Go checksum database (`sum.golang.org`) | The checksum database key built into Debian's Go |
| npm agents and Playwright | `npm audit signatures` before install scripts run; provenance where published | The npm registry's signing keys; Sigstore for codex, pi, and Playwright |
| Matt Pocock's skills | git object hashes for the commit read from GitHub's API | GitHub and HTTPS |

Claude Code, Copilot, opencode, and firebase-tools publish no npm provenance,
so they rely on the registry's signatures alone.

Playwright's own browser downloads are checked only by HTTPS, so the image
does not install them. `/opt/google/chrome/chrome` links to Debian's signed
`chromium`, which Playwright uses through its `chrome` channel: set
`channel: 'chrome'` in test configurations (Playwright MCP uses it by default).
The `Dockerfile` keeps a commented-out step for Firefox and WebKit; uncomment it
and rebuild to test with them, accepting unverified downloads.

`install-host-toolchain.sh` uses the same trust roots, with these
differences. It first checks that every apt source is the standard Debian
archive or security repository signed by the Debian archive keyring, and that
no apt setting weakens authentication. It installs the latest tea, Plannotator,
and gogcli releases when they verify, otherwise the `Dockerfile` versions. gogcli's Go
downloads go through a temporary local proxy (`go-ipv4-proxy.py`) that only
forces IPv4; Go still verifies TLS and the checksum database. Its own state
records live in `/var/lib/devcarone-host-toolchain`.

When updating a pinned version, refresh its trust data: the base image digest,
the archive key list when Debian adds keys, `keys/nodejs-release.asc` and its
fingerprint list when Node's README changes its releasers, or
`keys/teabot.asc` before it expires in June 2027.

## Configuration

Settings come from environment variables, then from `devcarone.env` beside the
launcher (symlinks to the launcher are followed), then from the defaults in the
table under "Launch". The file holds one `SETTING=value` per line, read
literally (no quotes or variable expansion), with `#` comments. It accepts only
the launcher settings in that table, except `GOG_KEYRING_PASSWORD`, which must
not be stored in a file. Set `DEVCAR_ENV_FILE` to read another file, or to an
empty value to read none. For example:

```sh
MAINDIR=/srv/devcarone
NETWORK=devnet
DNS=10.0.0.53
FORGEJO_URL=https://forgejo.example.com:3000
FORGEJO_USER=your-forgejo-user
```

Copy `devcarone.env.example` to `devcarone.env` beside the launcher and
uncomment the settings you need. The local file is ignored by Git and excluded
from the Docker build context. Keep deployment values and credentials out of
commits; with no local file, the generic defaults apply.

State lives in `MAINDIR`, by default `~/.local/share/devcarone` (under
`XDG_DATA_HOME` when set). It must contain:

```text
master_config/
  config/
  pki/
  vscode/
  codex/
  claude/
  Xresources
authorized_keys       # required only for --vnc
ssh_host_keys/        # created by the first --vnc launch
forgejo/token         # optional Forgejo personal access token
```

Use your existing master configuration. These directories map to the container
user's `.config`, `.pki`, `.vscode`, `.codex`, `.claude`, and `.Xresources`.
All session configuration must be accessible to the UID used for the build.
Each launch creates a new dated overlay; writes stay in that session's `upper/`
directory. The current working directory mounts at `~/src`.

The dedicated `authorized_keys` file contains the **public** SSH keys allowed to
access devcar. It is separate from the host account's `~/.ssh/authorized_keys`.
For example, to authorize one existing public key:

```sh
install -m 600 ~/.ssh/id_ed25519.pub "$MAINDIR/authorized_keys"
```

The file should be owned by the launching user (or root and readable by the
container user), with no group/other write permission. It is mounted read-only.
No private key is copied into the container. There is no password SSH login.

The first `--vnc` launch creates `ssh_host_keys/ssh_host_ed25519_key` (directory
mode `0700`) and every later launch reuses it, so the container keeps one SSH
identity and `known_hosts` entries stay valid. Set `SSH_HOST_KEY_DIR` to keep it
elsewhere. The key is mounted read-only and copied to a root-only file at
startup. Keep it out of Git; delete it to rotate the identity.

## Launch

From your project directory, run the launcher by its full path, or add this
directory to your PATH:

```sh
/path/to/devcarone/devcarone
/path/to/devcarone/devcarone --vnc
/path/to/devcarone/devcarone --vnc --name work
```

The launcher starts the container in the background and returns; closing its
terminal or pressing Ctrl-C does not stop the session. Stop it with
`docker stop CONTAINER_NAME` (the name is printed at launch; `docker ps` lists
running sessions). At launch, `sudo` starts a small root watcher, detached
from the terminal, that waits for the container to stop, appends its output to
the session's `session.log`, removes the container, and only then unmounts the
overlay. Check `session.log` if a session ends unexpectedly.

To confirm a stopped session was cleaned up, on the Docker host:

```sh
tail -n 3 SESSION_DIR/session.log    # ends with "devcarone: unmounted …/merged."
findmnt -t overlay -o TARGET | grep -F /path/to/MAINDIR   # only running sessions
docker ps --filter name=devcarone-   # running sessions
```

`SESSION_DIR` is the "Session files" directory printed at launch, inside
`MAINDIR` (see "Configuration"); Docker's own overlay mounts are filtered out
by the path. A session
still listed by `findmnt` after its container is gone was not unmounted; its
`session.log` says why.

The default starts a terminal on the host X display. It uses the host X socket
directory and a fresh temporary Xauthority file for each launch. Closing the
container's terminal stops the container; the watcher then unmounts the overlay
and deletes the Xauthority file.

Terminals use the account's configured shell (Bash in this image), including its
`.bashrc` prompt. Alt+Up and Alt+Down use explicit modified-arrow
sequences so terminal applications do not receive an extra Escape key.

Interactive Bash terminals include a `code` alias for
`code --no-sandbox --force-device-scale-factor=1.65 --wait`. Run `code .` or
`code path/to/file` as usual; additional arguments are passed through.

For mouse copying in urxvt, drag to select and middle-click to paste. If an
application captures mouse events, hold Shift while dragging. To copy selected
text to the desktop clipboard for Ctrl+V in other applications, press Ctrl+Alt+C.
These are urxvt's [selection and mouse-reporting controls](https://manpages.debian.org/trixie/rxvt-unicode/urxvt.1.en.html#MOUSE_REPORTING).

`--vnc` starts TigerVNC on display `:99` (TCP port `5999`) with an Openbox
desktop, with SSH on container port `22`. VNC listens only on container localhost;
no host ports are published, and SSH only forwards to `127.0.0.1:5999`. The
launcher prints the container IP and tunnel commands for the Docker host and,
through the Docker host as a jump host, for other machines.

Give each session a name to run several at once and reach them by name:

```sh
devcarone --vnc --name work
devcarone --vnc --name play
```

The containers are `devcarone-work` and `devcarone-play` (names are 1-32
lowercase letters, digits, or inner hyphens; the launcher refuses a name that
is already in use). Without `--name`, the container is named after its session
directory.

Copy `client/devcarone-ssh` from this repository to the SSH client, for
example:

```sh
scp DOCKER_HOST:/path/to/devcarone/client/devcarone-ssh ~/.local/bin/
```

Then, on the client:

```sh
devcarone-ssh DOCKER_HOST work    # shell in devcarone-work, VNC at 127.0.0.1:15999
devcarone-ssh DOCKER_HOST play    # shell in devcarone-play, VNC at 127.0.0.1:16000
```

`DOCKER_HOST` is the Docker host's SSH name; your account there must be able
to run `docker`. Each command opens a shell in the session (or runs a command
given after the name) and forwards the session's VNC desktop to its own local
port while the shell is open; it prints the port to point your viewer at.
Exiting the shell closes the tunnel. A second `devcarone-ssh` to the same
session warns that the port is in use and opens the shell anyway, since the
first one already forwards it. No `~/.ssh/config` entry is needed.

How it works: the launcher gives each running VNC session a local port,
starting at 15999 and skipping ports held by other running sessions, and
records it with the login user in the container's `devcarone.vnc-port` and
`devcarone.user` labels. `devcarone-ssh` asks the Docker host for the
container's address and labels in one `docker inspect`, then connects through
the host as `ProxyJump` would. That is two connections to the Docker host, so
with password login you are prompted twice; key-based login or connection
sharing avoids that:

```text
Host DOCKER_HOST
    ControlMaster auto
    ControlPath ~/.ssh/cm-%C
    ControlPersist 10m
```

Every session uses the persistent host key under the `known_hosts` alias
`devcarone`, so the key is confirmed once for all sessions. The forward must
target `127.0.0.1:5999`; other destinations are refused. The recorded port only
avoids other devcarone sessions; if something else on the client uses it, use
the launcher's printed `ssh -N -J … -L PORT:127.0.0.1:5999 …` command with
another port. The lookup expects the container on one Docker network, which
is how the launcher starts it.

For tools that make their own SSH connection (`scp`, `rsync`, editors), add
an optional entry that uses the script as a `ProxyCommand`:

```text
Host devcarone-*
    User BUILD_USER
    HostKeyAlias devcarone
    ProxyCommand ~/.local/bin/devcarone-ssh --proxy DOCKER_HOST %h
```

with `BUILD_USER` replaced by the build account, then for example
`scp file devcarone-work:src/`.

Alternatively, fix one session's address with `DEVCAR_IP`. Docker accepts a
fixed address only on a user-defined network with a configured subnet, so
`DEVCAR_IP` requires `NETWORK`. Choose an unused address inside the subnet but
outside the network's `--ip-range`, so Docker never assigns it to another
container. Set it per launch rather than in `devcarone.env`, or a second
session fails because the address is taken. For example:

```sh
docker network create --subnet 172.30.0.0/24 --ip-range 172.30.0.128/25 devnet
NETWORK=devnet DEVCAR_IP=172.30.0.10 devcarone --vnc
```

and a client entry for that address:

```text
Host devcar
    HostName 172.30.0.10
    User BUILD_USER
    ProxyJump DOCKER_HOST
    LocalForward 15999 127.0.0.1:5999
```

The desktop's Openbox, tint2, and solid background configuration is installed in
`/opt/devcar/desktop` because `~/.config` is mounted from the
session overlay. Right-click the desktop for the menu, or press Super+Return for
a terminal. VNC terminals use an 8-point font with `Xft.dpi` from `XFT_DPI`, which
overrides the host-oriented `Xft.dpi` in `Xresources`; X mode keeps 13 points.
`GDK_SCALE`, `GDK_DPI_SCALE`, and `QT_SCALE_FACTOR` scale GTK and Qt
applications. Change them to suit your viewer, then relaunch.

The desktop survives closing the terminal, disconnecting the viewer, or closing
the SSH tunnel, and does not depend on the launcher's terminal. Run
`docker stop CONTAINER_NAME` to end it; logging out of Openbox also ends the
session.

SSH logins use the same account as the desktop. Login shells receive the VNC
`DISPLAY`, `XAUTHORITY`, and scaling settings so graphical tools can join that
desktop at the same size.

| Setting | Default |
| --- | --- |
| `MAINDIR` | `~/.local/share/devcarone` |
| `DEVCAR_IMAGE` | `devcarone:v1` |
| `NETWORK` | unset (Docker's default bridge network) |
| `DNS` | unset (Docker's default resolver) |
| `VNC_GEOMETRY` | `1920x1080` |
| `VNC_DEPTH` | `24` |
| `VNC_DPI` | `168` |
| `VNC_FONT_SIZE` | `8` (VNC terminal points) |
| `XFT_DPI` | `$VNC_DPI` |
| `GDK_SCALE` | `1.8` |
| `GDK_DPI_SCALE` | `0.5` |
| `QT_SCALE_FACTOR` | `1.8` |
| `DEVCAR_IP` | unset (Docker assigns an address) |
| `DEVCAR_SKILLS` | `1` (`0` removes the image's skill links) |
| `SSH_HOST_KEY_DIR` | `$MAINDIR/ssh_host_keys` |
| `FORGEJO_TOKEN_FILE` | `$MAINDIR/forgejo/token` (Forgejo access only if present) |
| `FORGEJO_URL` | unset (required with a token) |
| `FORGEJO_USER` | unset (required with a token) |
| `GOGCLI_STATE_HOME` | `$MAINDIR/gogcli` (host auth directory) |
| `GOG_HOME` | `/home/BUILD_USER/.gogcli` (container auth directory) |
| `GOG_KEYRING_BACKEND` | `file` |
| `GOG_ACCOUNT` | unset (optional default account) |
| `GOG_KEYRING_PASSWORD` | unset (prompted when an account uses the file keyring; environment only) |

`NETWORK` and `DNS` name an existing Docker network and DNS server; the launcher
does not create them.

Session directories are retained after unmounting; only the container and the
temporary Xauthority file are removed. If the launch fails before the container
starts, the launcher cleans up itself. If the watcher is killed or the host
crashes, stop/remove the named container before manually unmounting the
printed `merged` directory.

## Verification

Run the automated checks without Docker or root. Python needs `tomlkit`, which
the image installs as Debian's `python3-tomlkit`. Outside the image, install it
in a virtual environment with `python3 -m pip install tomlkit` before testing.

```sh
bash -n devcarone entrypoint.sh install-tooling.sh link-skills.sh \
    forgejo/configure-forgejo.sh
sh -n desktop/xstartup desktop/devcar-terminal forgejo/tea forgejo/forgejo-credential \
    client/devcarone-ssh
python3 -m unittest discover -s tests -v
git diff --check
```

These use command substitutes at the Docker/mount/Xauth boundary to check quoting,
mode selection, failure exit codes, and the detached cleanup order. They do not prove real X,
VNC, SSH, graphics, or image-build functionality.
The Codex configuration tests also cover fresh/repeated setup, preserving user
settings and hooks, inline TOML, invalid input, and symlinked configuration.

After building on your Docker host:

1. Start X mode, confirm the launcher returns, the terminal opens, and the
   workspace/configuration are available. Close the terminal; check that the container is gone and the
   session's `merged` directory is no longer mounted.
   In the terminal, check that `echo "$SHELL"` reports `/bin/bash` and the Bash
   prompt appears. Check selection/paste and Alt+Up/Alt+Down in your terminal app.
2. With `DISPLAY` unset, start `--vnc --name work` and `--vnc --name play`.
   Connect to each with `devcarone-ssh DOCKER_HOST work` (and `play`) and a
   viewer on the printed port. Confirm the solid background, tint2 panel, Openbox menu, and a
   readable terminal font; closing that terminal and reconnecting the viewer
   should leave the desktop running. Confirm a third `--name work` launch is
   refused, and that SSH reports no changed host key after a relaunch.
3. Inspect listeners with `docker exec CONTAINER_NAME ss -lnt` (or `netstat -lnt`):
   `5999` must listen only on loopback. Confirm SSH accepts the dedicated key and
   rejects a key absent from that file.
4. Close the launcher's terminal and confirm the session keeps running. Run
   `docker stop CONTAINER_NAME`; confirm container removal, overlay unmount,
   and the container's output in `session.log`. Repeat with
   `docker rm -f CONTAINER_NAME`.
5. In a rebuilt container, run `plannotator --version`, then open Codex in a
   project and check `/skills` for `grill-me` and `plannotator-review`. Review
   the Plannotator hook under `/hooks` if prompted. Try `$plannotator-annotate
   README.md` and submit feedback in Chromium; confirm it returns to Codex.
   Try a plan-mode turn to verify automatic plan review as well.
   In Claude Code, check that `/` lists `tdd` and `plannotator-review`, and that
   leaving plan mode opens the plan in Plannotator; in opencode, check that the
   same skills are listed. Relaunch with `DEVCAR_SKILLS=0` and confirm the image
   skills are gone from all three agents.
6. Run `gog --version` and `gog --help` in both X and VNC terminals to confirm
   the source-built `gog` is available to the container user.
   After authorizing, run `gog auth doctor --check --no-input`, close the
   container, relaunch with the same account/password, and repeat to confirm
   authentication survives container removal.
7. With `forgejo/token` present, run `tea login list`, `tea issues list` inside a
   Forgejo clone, and `git push` of a test branch. Confirm a direct push to the
   protected `main` is rejected, and that a launch without the file has no
   `credential.*` entries in `git config --system --list`.
8. In a project using `@playwright/test` with `channel: 'chrome'`, run a test
   headless and headed; confirm it launches Debian's chromium.

TigerVNC flags and its explicit `-xstartup` option follow the
[Debian Trixie manual](https://manpages.debian.org/trixie/tigervnc-standalone-server/tigervncserver.1.en.html).

## License

This project is licensed under the [MIT License](LICENSE). Third-party software
and skills installed by the image retain their respective licenses.
