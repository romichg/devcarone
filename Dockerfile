# Pinned by digest: Docker refuses any other content for this tag. Update the
# digest deliberately (docker buildx imagetools inspect debian:trixie-slim).
FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a
ENV DEBIAN_FRONTEND=noninteractive
ENV NODE_DISTRO=linux-x64

ARG UID=1000
ARG GID=1000
# Build for the launching account: see README, "Build".
ARG USER=dev
ENV DEVCAR_USER=${USER}
# Fail in seconds, not at user creation, when build arguments are malformed.
RUN case "${UID}:${GID}" in \
        *[!0-9:]*|:*|*:) echo "UID and GID must be numbers, got UID='${UID}' GID='${GID}'. See README, Build." >&2; exit 1 ;; \
    esac; \
    case "${USER}" in \
        ''|-*|*[!A-Za-z0-9_.-]*) echo "USER must be a plain account name, got '${USER}'. See README, Build." >&2; exit 1 ;; \
    esac

# Override with --build-arg TZ=Region/City; see README, "Build".
ARG TZ=America/New_York
ENV TZ=${TZ}
ENV LIBVA_DRIVER_NAME=iHD

# Intel media drivers are in non-free.
RUN sed -i 's/^Components: main$/Components: main contrib non-free non-free-firmware/' \
    /etc/apt/sources.list.d/debian.sources

#Install prereqs
RUN apt-get update && apt-get -y upgrade && \
    apt-get -y --no-install-recommends install \
        sudo procps locales lsof file dialog gosu tzdata \
        curl wget ca-certificates apt-transport-https gnupg \
        net-tools netcat-traditional \
        rsyslog logrotate \
        openssh-server rsync xauth \
        tigervnc-standalone-server openbox tint2 feh x11-xserver-utils \
        rxvt-unicode pulseaudio mesa-utils vainfo libva2 \
        intel-media-va-driver-non-free libpci3 \
        fontconfig fonts-dejavu fonts-noto-core fonts-liberation \
        vim strace ripgrep jq \
        unzip 7zip xz-utils poppler-utils fonts-noto ffmpeg imagemagick \
        pandoc texlive-xetex texlive-latex-base \
        texlive-latex-recommended texlive-latex-extra lmodern \
        chromium \
        build-essential git \
        golang-go \
        python3 python3-pip python3-venv python3-pytest python3-yaml python3-tomlkit \
        cosign && \
    rm -rf /var/lib/apt/lists/*

# apt trusts only the keys in debian-archive-keyring.pgp (Signed-By in
# debian.sources). Fail if it holds any key besides Debian's 11-13 archive,
# security, and release keys, checked against
# https://ftp-master.debian.org/keys.html on 2026-10-04.
RUN allowed=" \
        04B54C3CDCA79751B16BC6B5225629DF75B188BD 5E04A1E3223A19A20706E20F9904613D4CCE68C6 \
        41587F7DB8C774BCCF131416762F67A0B2C39DE4 B8B80B5B623EAB6AD8775C45B7C5D7D6350947F8 \
        05AB90340C0C5E797F44A8C8254CF3B5AEC0A8F0 4D64FEC119C2029067D6E791F8D2585B8783D481 \
        1F89983E0081FDE018F3CC9673A4F27B8DD47936 AC530D520F2F3269F5E98313A48449044AAD5C5D \
        A4285295FC7B1A81600062A9605C66F00D6C9793 "; \
    grep -qx 'Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp' \
        /etc/apt/sources.list.d/debian.sources; \
    keys=$(gpg --show-keys --with-colons /usr/share/keyrings/debian-archive-keyring.pgp \
        | awk -F: '$1 == "pub" { p = 1; next } $1 == "fpr" && p { print $10; p = 0 }'); \
    [ -n "$keys" ]; \
    for key in $keys; do \
        case "$allowed" in *" $key "*) ;; *) echo "Unexpected Debian archive key $key" >&2; exit 1 ;; esac; \
    done

# Update Locales
RUN echo "en_US.UTF-8 UTF-8" > /etc/locale.gen \
    && locale-gen \
    && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime \
    && echo "$TZ" > /etc/timezone

#Copy package
# 1. Install our official public software signing key
COPY microsoft.asc.gpg /root
RUN install -o root -g root -m 644 /root/microsoft.asc.gpg /usr/share/keyrings/; \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.asc.gpg] \
https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list

# Install code
RUN apt-get update && apt-get install -y --no-install-recommends code

# ── Node.js LTS from nodejs.org, GPG-verified ───────────────────────────
# keys/nodejs-release.asc holds the current releasers' public keys, exported
# from keyserver.ubuntu.com; their fingerprints below match the "Release keys"
# list in Node's README (checked 2026-10-04). SHASUMS256.txt must be signed by
# one of them. A release signed by a new releaser fails here: add their key.
COPY keys/nodejs-release.asc /tmp/nodejs-release.asc
RUN set -eux; \
    releasers=" \
        5BE8A3F6C8A5C01D106C0AD820B1A390B168D356 DD792F5973C6DE52C432CBDAC77ABFA00DDBF2B7 \
        CC68F5A3106FF448322E48ED27F5E38D5B0A215F 890C08DB8579162FEE0DF9DB8BEAB4DFCF555EF4 \
        C82FA3AE1CBEDC6BE46B9360C43CEC45C17AB93C 108F52B48DB57BB0CC439B2997B01419BD92F80A \
        655F3B5C1FB3FA8D1A0CA6BDE4A7D232B936D2FD A363A499291CBBC940DD62E41F10027AF002F8B0 "; \
    export GNUPGHOME="$(mktemp -d)"; \
    cd "$GNUPGHOME"; \
    gpg --batch --quiet --import /tmp/nodejs-release.asc; \
    curl -fsSL https://nodejs.org/dist/index.json -o index.json; \
    NODE_VERSION=$(jq -r '[.[] | select(.lts != false)] | .[0].version[1:]' index.json); \
    echo "Resolved latest LTS: v${NODE_VERSION}"; \
    BASE_URL="https://nodejs.org/dist/v${NODE_VERSION}"; \
    TARBALL="node-v${NODE_VERSION}-${NODE_DISTRO}.tar.xz"; \
    curl -fsSLO "${BASE_URL}/${TARBALL}"; \
    curl -fsSLO "${BASE_URL}/SHASUMS256.txt"; \
    curl -fsSLO "${BASE_URL}/SHASUMS256.txt.sig"; \
    signer=$(gpg --batch --status-fd 1 --verify SHASUMS256.txt.sig SHASUMS256.txt \
        | awk '$2 == "VALIDSIG" { print $NF }'); \
    case "$releasers" in *" ${signer:-none} "*) ;; *) echo "Unexpected Node signer: ${signer:-none}" >&2; exit 1 ;; esac; \
    grep " ${TARBALL}\$" SHASUMS256.txt | sha256sum -c -; \
    tar -xJf "${TARBALL}" -C /usr/local --strip-components=1; \
    cd /; rm -rf "$GNUPGHOME" /tmp/nodejs-release.asc

WORKDIR /
ENV PATH=/usr/local/bin:$PATH

# Install AI CLI agents  ────────────────────
# Lifecycle scripts wait until npm has verified registry signatures (and
# provenance attestations, where packages publish them) below.
RUN npm install -g --ignore-scripts @openai/codex
RUN npm install -g --ignore-scripts @github/copilot
RUN npm install -g --ignore-scripts opencode-ai
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent
RUN npm install -g --ignore-scripts @anthropic-ai/claude-code
RUN npm install -g --ignore-scripts firebase-tools
RUN npm install -g --ignore-scripts @playwright/test
# npm audit refuses -g, but works from the global prefix. pi stays without
# install scripts, as before.
RUN cd /usr/local/lib && npm audit signatures \
    && npm rebuild -g @openai/codex @github/copilot opencode-ai \
       @anthropic-ai/claude-code firebase-tools @playwright/test

# Gitea's tea CLI for Forgejo issues and pull requests; /usr/local/bin/tea is a
# wrapper that selects the login generated from the mounted token. The release's
# checksums.txt is signed by Gitea's Teabot key (keys/teabot.asc), whose
# fingerprint matches https://docs.gitea.com/installation/install-from-binary.
ARG TEA_VERSION=0.16.0
COPY keys/teabot.asc /tmp/teabot.asc
RUN set -eux; \
    key=7C9E68152594688862D62AF62D9AE806EC1592E2; \
    asset="tea-${TEA_VERSION}-linux-amd64"; \
    base="https://gitea.com/gitea/tea/releases/download/v${TEA_VERSION}"; \
    export GNUPGHOME="$(mktemp -d)"; \
    cd "$GNUPGHOME"; \
    gpg --batch --quiet --import /tmp/teabot.asc; \
    curl -fsSLO "$base/checksums.txt"; \
    curl -fsSLO "$base/checksums.txt.sig"; \
    gpg --batch --status-fd 1 --verify checksums.txt.sig checksums.txt \
        | grep -q "^\[GNUPG:\] VALIDSIG .* ${key}\$"; \
    curl -fsSLO "$base/$asset"; \
    grep " ${asset}\$" checksums.txt | sha256sum --check; \
    install -D -m 755 "$asset" /opt/devcar/bin/tea; \
    cd /; rm -rf "$GNUPGHOME" /tmp/teabot.asc; \
    /opt/devcar/bin/tea --version
ENV PLANNOTATOR_BROWSER=/usr/bin/chromium
# Both X and VNC use the browser inside the container, including SSH launches.
ENV PLANNOTATOR_REMOTE=0

# Playwright's own browser downloads are not hash-checked, so Playwright uses
# Debian's signed chromium through its "chrome" channel (channel: 'chrome' in
# test configs; Playwright MCP's default browser).
RUN mkdir -p /opt/google/chrome && ln -s /usr/bin/chromium /opt/google/chrome/chrome
# To test Firefox or WebKit, uncomment and rebuild. These downloads are verified
# only by HTTPS, not by signature or pinned hash.
# ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
# RUN mkdir -p /ms-playwright \
#  && playwright install --with-deps firefox webkit \
#  && chmod -R a+rX /ms-playwright

# gogcli from source: the Go checksum database (sum.golang.org, a signed
# transparency log whose key is built into Debian's Go) verifies gogcli, its
# dependencies, and the newer Go toolchain that GOTOOLCHAIN=auto downloads.
ARG GOGCLI_VERSION=v0.43.0
RUN set -eux; \
    export GOPATH=/tmp/go GOCACHE=/tmp/go-cache GOBIN=/usr/local/bin \
        GOTOOLCHAIN=auto GOSUMDB=sum.golang.org GOFLAGS=-modcacherw; \
    go install "github.com/openclaw/gogcli/cmd/gog@${GOGCLI_VERSION}"; \
    rm -rf /tmp/go /tmp/go-cache; \
    gog --version

RUN npm cache clean --force

# ── Create user ────────────
RUN (getent group ${GID} || groupadd --gid ${GID} ${USER}) && \
    (getent group audio || groupadd audio) && \
    (getent group video || groupadd video) && \
    useradd -m -s /bin/bash -u ${UID} -g ${GID} -G audio,video ${USER}

# VNC startup uses the launcher's persistent host key, not image keys.
RUN rm -f /etc/ssh/ssh_host_* && mkdir -p /run/devcar

# ── Drop privileges ───────────────────────────────────────────────────────
USER ${USER}
WORKDIR /home/${USER}

RUN echo "alias code='code --no-sandbox --force-device-scale-factor=1.65 --wait'" >> /home/${USER}/.bashrc

RUN node --version && npm --version

COPY entrypoint.sh /entrypoint.sh
COPY configure-codex.py /configure-codex.py
COPY configure-claude.py /configure-claude.py
COPY link-skills.sh /link-skills.sh
# Desktop configuration lives outside the mounted ~/.config.
COPY desktop/ /opt/devcar/desktop/
COPY forgejo/ /opt/devcar/forgejo/

USER root
# Shared agent skills and Plannotator live outside the mounted home directories;
# startup links the skills for Codex, Claude Code, and opencode. Matt Pocock's
# skills follow the branch his Claude Code plugin is published from. The commit
# description changes when the branch moves, which reruns only these late layers.
ARG MATT_POCOCK_REF=main
ARG PLANNOTATOR_VERSION=v0.27.21
ADD https://api.github.com/repos/mattpocock/skills/commits/${MATT_POCOCK_REF} /tmp/matt-pocock-commit.json
COPY install-tooling.sh /opt/devcar/install-tooling.sh
RUN commit=$(jq -er .sha /tmp/matt-pocock-commit.json) \
    && rm /tmp/matt-pocock-commit.json \
    && bash /opt/devcar/install-tooling.sh "$commit" "$PLANNOTATOR_VERSION"
RUN chmod 755 /entrypoint.sh /link-skills.sh \
    && chmod -R a+rX /opt/devcar/desktop /opt/devcar/forgejo \
    && chmod 755 /opt/devcar/desktop/xstartup /opt/devcar/desktop/devcar-terminal \
       /opt/devcar/forgejo/tea /opt/devcar/forgejo/forgejo-credential \
       /opt/devcar/forgejo/configure-forgejo.sh \
    && ln -s /opt/devcar/desktop/devcar-terminal /usr/local/bin/devcar-terminal \
    && ln -s /opt/devcar/forgejo/tea /usr/local/bin/tea \
    && ln -s /opt/devcar/forgejo/forgejo-credential /usr/local/bin/forgejo-credential
ENTRYPOINT ["/entrypoint.sh"]
CMD ["x"]
