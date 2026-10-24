#!/usr/bin/env bash
set -euo pipefail

: "${DEVCAR_USER:?Missing image user}"
if [[ $(id -u "$DEVCAR_USER") != "${LOCAL_UID:-$(id -u "$DEVCAR_USER")}" ]]; then
    echo 'Image user does not match host UID; rebuild with your UID and username.' >&2
    exit 1
fi
# gosu resets supplementary groups, so set membership in the account database.
if [[ -n ${RENDER_GID:-} ]]; then
    getent group "$RENDER_GID" >/dev/null || groupadd --gid "$RENDER_GID" devcar-render
    usermod -a -G "$RENDER_GID" "$DEVCAR_USER"
fi
USER_HOME=$(getent passwd "$DEVCAR_USER" | cut -d: -f6)
USER_SHELL=$(getent passwd "$DEVCAR_USER" | cut -d: -f7)
# Unlike the old sudo launcher, gosu does not initialize SHELL. Without it,
# urxvt falls back to /bin/sh and never loads the user's Bash prompt/config.
AS_USER=(gosu "$DEVCAR_USER" env "HOME=$USER_HOME" "USER=$DEVCAR_USER"
         "LOGNAME=$DEVCAR_USER" "SHELL=$USER_SHELL" LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8)

# The launcher mounts ~/.codex over the image's home. Merge only the integration
# settings now, as the account owner; binaries and skills stay in the image.
ENTRYPOINT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
"${AS_USER[@]}" python3 "$ENTRYPOINT_DIR/configure-codex.py"
"${AS_USER[@]}" python3 "$ENTRYPOINT_DIR/configure-claude.py"
# Link the image's skills for Codex and for Claude Code; opencode also reads
# ~/.claude/skills. DEVCAR_SKILLS=0 removes the links instead.
case ${DEVCAR_SKILLS:-1} in
    1) SKILLS=on ;;
    0) SKILLS=off ;;
    *) echo 'DEVCAR_SKILLS must be 0 or 1.' >&2; exit 2 ;;
esac
"$ENTRYPOINT_DIR/link-skills.sh" "${CODEX_SKILLS_DIR:-/etc/codex/skills}" "$SKILLS"
"${AS_USER[@]}" "$ENTRYPOINT_DIR/link-skills.sh" \
    "${CLAUDE_CONFIG_DIR:-$USER_HOME/.claude}/skills" "$SKILLS"
# Optional: the launcher mounts a Forgejo token only when one is configured.
if [[ -e ${FORGEJO_TOKEN_PATH:-/run/devcar/forgejo-token} ]]; then
    /opt/devcar/forgejo/configure-forgejo.sh
fi

case "${1:-x}" in
    x) exec "${AS_USER[@]}" devcar-terminal ;;
    vnc) ;;
    *) echo 'Expected x or vnc mode.' >&2; exit 2 ;;
esac

: "${VNC_GEOMETRY:=1920x1080}"
: "${VNC_DEPTH:=24}"
: "${VNC_DPI:=168}"
: "${VNC_FONT_SIZE:=8}"
: "${XFT_DPI:=$VNC_DPI}"
: "${GDK_SCALE:=1.8}"
: "${GDK_DPI_SCALE:=0.5}"
: "${QT_SCALE_FACTOR:=1.8}"
for path in authorized_keys ssh_host_ed25519_key; do
    if [[ ! -s /run/devcar/$path ]]; then
        echo "Missing dedicated /run/devcar/$path file." >&2
        exit 1
    fi
done
"${AS_USER[@]}" test -r /run/devcar/authorized_keys
mkdir -p /run/sshd
# The launcher keeps one host key so SSH client entries survive relaunches.
# Read it as the owner (root may be squashed on network storage); sshd needs
# a root-owned private copy.
install -m 600 /dev/null /run/devcar/host_key
"${AS_USER[@]}" cat /run/devcar/ssh_host_ed25519_key > /run/devcar/host_key
cat > /run/devcar/sshd_config <<EOF
Port 22
HostKey /run/devcar/host_key
UsePAM yes
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile /run/devcar/authorized_keys
AllowUsers $DEVCAR_USER
AllowTcpForwarding local
PermitOpen 127.0.0.1:5999
X11Forwarding no
Subsystem sftp internal-sftp
EOF

# Desktop display and scaling, also given to graphical tools launched from an
# SSH login so they join the VNC desktop at the same size.
DESKTOP_ENV=(DISPLAY=:99 "XAUTHORITY=$USER_HOME/.Xauthority"
             "URXVT_FONT_SIZE=$VNC_FONT_SIZE" "XFT_DPI=$XFT_DPI"
             "GDK_SCALE=$GDK_SCALE" "GDK_DPI_SCALE=$GDK_DPI_SCALE"
             "QT_SCALE_FACTOR=$QT_SCALE_FACTOR")
for setting in "${DESKTOP_ENV[@]}"; do
    printf 'export %s=%q\n' "${setting%%=*}" "${setting#*=}"
done > /etc/profile.d/devcar.sh
if [[ -n ${PULSE_SERVER:-} ]]; then
    printf 'export PULSE_SERVER=/tmp/pulse/native\n' >> /etc/profile.d/devcar.sh
fi

SSHD_PID=
VNC_PID=
cleanup() {
    trap - EXIT INT TERM HUP
    [[ -z $SSHD_PID ]] || kill "$SSHD_PID" 2>/dev/null || true
    [[ -z $VNC_PID ]] || kill "$VNC_PID" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
/usr/sbin/sshd -D -e -f /run/devcar/sshd_config &
SSHD_PID=$!
# Explicit startup path works independently of TigerVNC's config-directory version.
"${AS_USER[@]}" "${DESKTOP_ENV[@]}" \
    tigervncserver :99 -fg -localhost yes -SecurityTypes None \
    -geometry "$VNC_GEOMETRY" -depth "$VNC_DEPTH" -dpi "$VNC_DPI" \
    -xstartup /opt/devcar/desktop/xstartup &
VNC_PID=$!
wait -n "$SSHD_PID" "$VNC_PID"
