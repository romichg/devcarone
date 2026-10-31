# Working on devcarone

## Purpose and scope

This repository builds a standalone Debian Trixie developer container and its
Linux host launcher. Read `README.md` for usage and verification instructions.
Keep it consistent with implementation changes.

## Architecture

- `Dockerfile` installs the developer toolchain and creates the host-matching
  user. The current image targets an x86_64 Linux host with Intel render device
  `/dev/dri/renderD128`; do not assume the whole image supports ARM just because
  the Plannotator installer does.
- `devcarone` runs on the Docker host. It creates a per-session OverlayFS layer
  over `$MAINDIR/master_config`, mounts selected configuration into the container,
  and mounts the launch directory at `~/src`. It starts the container in the
  background and returns; a root watcher started with `sudo setsid -f` waits
  for the container, saves its output to `session.log`, removes it, and
  unmounts the overlay. Settings come from the
  environment, then `devcarone.env` beside the launcher (literal `KEY=VALUE`
  lines limited to the launcher's `SETTINGS` list), then generic defaults.
- `entrypoint.sh` starts as root for account/group and SSH setup, then uses `gosu`
  to run user programs. Default `x` mode runs `devcar-terminal` on the host X
  display. `vnc` mode generates `/run/devcar/sshd_config`, starts sshd, and runs
  TigerVNC on `:99` (port 5999, loopback) with `desktop/xstartup`.
- `desktop/` is copied to `/opt/devcar/desktop`: the Openbox `rc.xml`/`menu.xml`,
  tint2 configuration, plus
  `xstartup` and `devcar-terminal` (urxvt font and key bindings for both modes,
  linked into `/usr/local/bin`). It lives outside `~/.config`, which the launcher
  mounts from the overlay. Pass config paths explicitly rather than relying on
  `~/.config` or `/etc/xdg` lookup.
- SSH access in `vnc` mode: the launcher creates one persistent ed25519 host key
  in `$SSH_HOST_KEY_DIR` (default `$MAINDIR/ssh_host_keys`) and mounts it with
  `$MAINDIR/authorized_keys`. `DEVCAR_IP` optionally fixes the container address.
  `--name NAME` names the container `devcarone-NAME`. Each VNC session gets
  a distinct client tunnel port from 15999; the launcher records it and the
  login user in the `devcarone.vnc-port` and `devcarone.user` labels.
  `client/devcarone-ssh DOCKER_HOST NAME` runs on the SSH client: it reads the
  address and labels in one `docker inspect` over SSH (`-n`,
  `ClearAllForwardings`), then opens a shell with the VNC forward through the
  host (`ssh -W`). `--proxy` mode serves an optional `Host devcarone-*`
  ProxyCommand; there a lookup that reads stdin would swallow the SSH
  protocol stream, so keep `-n`. Changes must keep `devcarone-ssh`, its proxy
  mode, and the fixed-address `DEVCAR_IP` entry working.
- `install-tooling.sh` runs at image build time. It installs Matt Pocock's skills
  and Plannotator's four core skills under `/opt/devcar/tooling` and writes
  `skills.list`: the skills named in Matt's Claude Code `plugin.json` (his
  published set) plus Plannotator's. Matt's skills follow his `main` branch: the
  Dockerfile `ADD`s the branch's commit description from the GitHub API to
  invalidate the cache and passes that commit to the installer, so keep the
  tooling layers near the end of the Dockerfile. Plannotator is pinned and
  installed in `/usr/local/bin` after `cosign` verifies its Sigstore SLSA
  provenance from the release workflow for that tag. Version
  defaults are Docker build arguments; update them and the README together.
- At startup, `link-skills.sh` links every listed skill into `/etc/codex/skills`
  (as root) and `~/.claude/skills` (as the user; Claude Code and opencode both
  read it), or removes those links when `DEVCAR_SKILLS=0`. It only adds or
  removes links that point into `/opt/devcar/tooling`. Skills are deliberately
  not installed as Claude Code plugins, so all three agents share one mechanism.
- `configure-codex.py` and `configure-claude.py` run as the container user after
  mounts are available. They merge Plannotator's hooks into `$CODEX_HOME`
  (default `~/.codex`; Stop hook and feature flag, using `tomlkit` to retain TOML
  formatting/comments) and `$CLAUDE_CONFIG_DIR/settings.json` (default
  `~/.claude`; the `ExitPlanMode` and `EnterPlanMode` hooks from Plannotator's
  Claude Code plugin).
- `forgejo/` is copied to `/opt/devcar/forgejo`. When `$FORGEJO_TOKEN_FILE`
  (default `$MAINDIR/forgejo/token`) exists, the launcher mounts it read-only at
  `/run/devcar/forgejo-token`; startup runs `configure-forgejo.sh` as root to add
  a system git credential helper scoped to `FORGEJO_URL` and a tea login in
  `/run/devcar/tea`. `/usr/local/bin/tea` wraps the pinned binary in
  `/opt/devcar/bin/tea` to select that login.
- gogcli is built at image build time with `go install` (checked by Go's
  checksum database) into `/usr/local/bin/gog`; Homebrew is not installed. The
  launcher mounts `$GOGCLI_STATE_HOME` at `GOG_HOME` to persist auth across
  sessions.
- Every download is checked against a trust root kept in the repository: the
  base image digest, Debian archive key fingerprints, committed or fingerprinted
  GPG keys, Sigstore identities, Go's checksum database, or npm registry
  signatures. A checksum fetched from the same server is not enough. README's
  "Download verification" lists each one; keep it current. Playwright uses
  Debian's chromium; its unverified browser downloads stay commented out.

## Requirements to preserve

- Keep installed skill sources, desktop configuration, and binaries outside
  mounted home directories (`.codex`, `.config`, and so on). Their bind mounts hide
  image-time files; only necessary configuration belongs there, merged at
  startup. Startup must not fetch dependencies from the network.
- Preserve unrelated user configuration, custom hooks, symlinks, and file
  permissions. Repeated startup must not duplicate hooks or create redundant
  hook files. Reject malformed configuration without overwriting it.
- Do not bypass Codex hook trust. `/hooks` review may be needed for a new
  session overlay. Linking a skill does not execute it or configure a project's
  workflows. Never replace or delete a user's own skill of the same name.
- Preserve `SHELL` initialization and Alt+Up/Down terminal bindings in both
  display modes; change terminal settings only in `devcar-terminal`. Mouse
  selection behavior is accepted as is.
- Remove/stop the container before unmounting its overlay. Retain session
  upper/work directories. Keep temporary Xauthority cleanup on failure/signals.
  Sessions must outlive the launcher's terminal; only stopping the container
  ends one.
- Keep VNC bound to loopback and SSH restricted to the dedicated public keys
  and the `127.0.0.1:5999` forward. Do not introduce password authentication or
  public VNC ports. Do not regenerate the host key per launch.
- Plannotator uses Chromium inside the X/VNC desktop. `~/.plannotator` is not
  persisted by the launcher; document any future change to data persistence.
- `GOG_KEYRING_PASSWORD` reaches the container as an environment variable, so it
  is visible to `docker inspect`. Do not log, print, or persist it anywhere else.
- Keep the Forgejo token out of environment variables, command lines, Git
  configuration, and mounted or overlay directories; Forgejo access stays
  optional. The token is readable by agents in the container by design; its
  limits come from Forgejo token scopes and branch protection.
- Keep site-specific values (user names, email addresses, host names, paths,
  networks, server URLs) out of code, tests, and documentation; they belong only
  in the ignored local `devcarone.env`; keep `devcarone.env.example` generic. Use generic
  examples such as `example.com` and documentation addresses instead.
- Never include credentials, SSH host keys, crash dumps, or virtual environments
  in commits, and keep `devcarone.env` and secrets out of the image build
  context; keep `.gitignore` and `.dockerignore` in sync. Strip metadata (EXIF/GPS)
  from images before committing. Preserve unrelated user work.

## Verification

Use Python 3.11+ and `tomlkit`. The image includes Debian's `python3-tomlkit`.
For development outside the image:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install tomlkit
PATH="$PWD/.venv/bin:$PATH" python3 -m unittest discover -s tests -v
bash -n devcarone entrypoint.sh install-tooling.sh link-skills.sh \
    forgejo/configure-forgejo.sh
sh -n desktop/xstartup desktop/devcar-terminal forgejo/tea forgejo/forgejo-credential \
    client/devcarone-ssh
git diff --check
```

Run `shellcheck` on changed scripts when it is available. The tests substitute
external Docker/mount/Xauth/gosu/ssh-keygen commands and point git at a temporary
`GIT_CONFIG_SYSTEM`; launcher tests set `DEVCAR_ENV_FILE` empty so the
repository's `devcarone.env` does not apply, and entrypoint tests set
`CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `CODEX_SKILLS_DIR`, `DEVCAR_TOOLING`,
`FORGEJO_TOKEN_PATH`, `GIT_CONFIG_SYSTEM`, and `TEA_CONFIG_HOME`.
Keep all test configuration in temporary directories; never mutate the real
user's Codex or Claude configuration. Add regression coverage when changing
configuration merging or launcher lifecycle behavior.

The tooling installer accepts a third argument for an empty staging root, so
downloads, provenance verification (with `cosign` on PATH), and the skill list
can be tested without root or Docker;
run `link-skills.sh` with `DEVCAR_TOOLING` pointing into that root to check the
links. The installer is intended for a fresh image layer or empty staging root.

Development usually happens inside a devcarone container without Docker. Docker
build and interactive X/VNC/SSH/Plannotator checks are separate from unit
tests. Follow the README verification steps when a suitable Docker host is
available. Report unperformed checks explicitly; passing tests alone is not a
successful image build or end-to-end release validation.
