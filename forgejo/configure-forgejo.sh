#!/usr/bin/env bash
# Startup Forgejo access, run as root when the launcher mounts a token: a git
# credential helper for the server URL and a tea login, both container-only.
set -euo pipefail
: "${DEVCAR_USER:?Missing image user}"
: "${FORGEJO_URL:?Missing Forgejo URL}"
: "${FORGEJO_USER:?Missing Forgejo user}"
TOKEN_PATH=${FORGEJO_TOKEN_PATH:-/run/devcar/forgejo-token}
TEA_HOME=${TEA_CONFIG_HOME:-/run/devcar/tea}
URL=${FORGEJO_URL%/}

# git honors GIT_CONFIG_SYSTEM, which the tests use instead of /etc/gitconfig.
git config --system "credential.$URL.helper" /usr/local/bin/forgejo-credential
git config --system "credential.$URL.username" "$FORGEJO_USER"

# Read as the owner: root may be squashed on network storage.
token=$(gosu "$DEVCAR_USER" cat "$TOKEN_PATH")
if [[ ! $token =~ ^[A-Za-z0-9_]+$ ]]; then
    echo 'Forgejo token must be a single line of letters, digits, or underscores.' >&2
    exit 1
fi
install -d -o "$DEVCAR_USER" -m 700 "$TEA_HOME" "$TEA_HOME/tea"
install -o "$DEVCAR_USER" -m 600 /dev/null "$TEA_HOME/tea/config.yml"
cat > "$TEA_HOME/tea/config.yml" <<EOF
logins:
  - name: "forgejo"
    url: "$URL"
    token: "$token"
    default: true
    user: "$FORGEJO_USER"
EOF
