#!/usr/bin/env bash
# Install the Dockerfile's toolchain on Debian Trixie, without its container runtime.
set -euo pipefail
umask 022
export DEBIAN_FRONTEND=noninteractive

# Tests run the installer against a marked temporary root that they own, with
# substitute commands in its test-bin. Production always uses / and uid 0.
if [[ -n ${DEVCAR_HOST_TOOLCHAIN_TEST_ROOT:-} ]]; then
    ROOT=$DEVCAR_HOST_TOOLCHAIN_TEST_ROOT
    [[ $ROOT == /* && -f $ROOT/.devcarone-host-toolchain-test-root ]] || {
        echo 'The installer test root must be absolute and marked.' >&2; exit 2; }
    OWNER_UID=$(stat -c %u -- "$ROOT")
    SYSTEM_PATH=$ROOT/test-bin:$ROOT/usr/bin
else
    ROOT= OWNER_UID=0 SYSTEM_PATH=/usr/sbin:/usr/bin:/sbin:/bin
fi
readonly ROOT OWNER_UID SYSTEM_PATH
export PATH=$SYSTEM_PATH:$ROOT/usr/local/bin

readonly SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly STATE_DIR=$ROOT/var/lib/devcarone-host-toolchain
readonly TOOL_DIR=$ROOT/usr/local/lib/devcarone-toolchain
readonly TOOLING_DIR=$ROOT/opt/devcar/tooling
readonly BIN_DIR=$ROOT/usr/local/bin
readonly APT_DIR=$ROOT/etc/apt
readonly MICROSOFT_KEYRING=$ROOT/usr/share/keyrings/devcarone-host-microsoft.gpg
readonly PROFILE_FILE=$ROOT/etc/profile.d/devcarone-host-toolchain.sh
readonly TOOLING_GENERATIONS=$ROOT/opt/devcar/host-toolchain/tooling
readonly NPM_REGISTRY=https://registry.npmjs.org/
readonly TEA_KNOWN=v0.16.0 PLANNOTATOR_KNOWN=v0.27.21 GOG_KNOWN=v0.43.0

UPDATE=0
TARGET_USER=
while (($#)); do
    case $1 in
        --update) UPDATE=1 ;;
        --user)
            (($# >= 2)) || { echo '--user needs an account name.' >&2; exit 2; }
            TARGET_USER=$2
            shift ;;
        --help|-h)
            echo 'Usage: sudo ./install-host-toolchain.sh [--update] [--user NAME]'
            echo 'Run from the public/ bundle on Debian Trixie x86_64.'
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }
require_file() { [[ -f $1 ]] || die "Missing bundle file $1"; }
require_file "$SCRIPT_DIR/keys/nodejs-release.asc"
require_file "$SCRIPT_DIR/keys/teabot.asc"
require_file "$SCRIPT_DIR/microsoft.asc.gpg"
require_file "$SCRIPT_DIR/install-tooling.sh"
require_file "$SCRIPT_DIR/link-skills.sh"
require_file "$SCRIPT_DIR/configure-codex.py"
require_file "$SCRIPT_DIR/configure-claude.py"
require_file "$SCRIPT_DIR/go-ipv4-proxy.py"
[[ $(id -u) == "$OWNER_UID" ]] || die 'Run as root (usually with sudo).'
# Do not try to adapt this image's x64 packages to another platform.
[[ $(dpkg --print-architecture) == amd64 ]] || die 'Debian amd64 is required.'
# shellcheck source=/dev/null
. "$ROOT/etc/os-release"
[[ ${ID:-} == debian && ${VERSION_CODENAME:-} == trixie ]] || die 'Debian Trixie is required.'
# Existing host commands are not ours to replace or shadow. Detect collisions
# per command, including non-executable files and dangling destination links.
declare -A PRESERVED_COMMANDS=()
preserve_command() {
    local name=$1 expected=${2:-} binary=$BIN_DIR/$1 existing
    [[ -z ${PRESERVED_COMMANDS[$name]:-} ]] || return 0
    if [[ -e $binary || -L $binary ]]; then
        if [[ -n $expected && -L $binary ]]; then
            case $(readlink -- "$binary") in
                "$expected"|"$TOOL_DIR/current-node/bin/$name"|"$TOOL_DIR/current-npm/node_modules/.bin/$name")
                    return 1 ;;
            esac
        fi
        if [[ -z $expected && -f $binary && ! -L $binary &&
              ( -f $STATE_DIR/$name.sha256 || -f $STATE_DIR/$name.sha256.new ) ]]; then
            return 1
        fi
        existing=$binary
    else
        existing=$(command -v "$name" || true)
        [[ -n $existing ]] || return 1
    fi
    PRESERVED_COMMANDS[$name]=$existing
    warn "Keeping existing $name at $existing; its command will not be installed or updated."
}
for command_name in code chromium; do
    command_path=$(command -v "$command_name" || true)
    if [[ -n $command_path && $command_path != $ROOT/usr/bin/$command_name &&
          $command_path != $ROOT/bin/$command_name ]]; then
        PRESERVED_COMMANDS[$command_name]=$command_path
        warn "Keeping existing $command_name at $command_path; skipping its apt package."
    fi
done

if [[ -z $TARGET_USER && -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    TARGET_USER=$SUDO_USER
fi
if [[ -n $TARGET_USER ]]; then
    id "$TARGET_USER" >/dev/null 2>&1 || die "Unknown account: $TARGET_USER"
    [[ $(id -u "$TARGET_USER") != 0 ]] || die 'Select a non-root account for agent configuration.'
fi

WORK=$(mktemp -d)
GO_PROXY_PID=
cleanup() {
    if [[ -n $GO_PROXY_PID ]]; then
        kill "$GO_PROXY_PID" 2>/dev/null || true
        wait "$GO_PROXY_PID" 2>/dev/null || true
    fi
    rm -rf -- "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
export GNUPGHOME=$WORK/gnupg
mkdir -m 700 "$GNUPGHOME"

primary_fingerprints() {
    gpg --show-keys --with-colons "$1" | awk -F: '$1 == "pub" { want = 1; next } $1 == "fpr" && want { print $10; want = 0 }'
}

verify_key_file() {
    local file=$1 allowed=$2 key found=0
    while IFS= read -r key; do
        [[ -z $key ]] && continue
        case " $allowed " in *" $key "*) ;; *) die "Unexpected key $key in $file" ;; esac
        found=1
    done < <(primary_fingerprints "$file")
    ((found)) || die "No signing key in $file"
}

readonly NODE_KEYS='5BE8A3F6C8A5C01D106C0AD820B1A390B168D356 DD792F5973C6DE52C432CBDAC77ABFA00DDBF2B7 CC68F5A3106FF448322E48ED27F5E38D5B0A215F 890C08DB8579162FEE0DF9DB8BEAB4DFCF555EF4 C82FA3AE1CBEDC6BE46B9360C43CEC45C17AB93C 108F52B48DB57BB0CC439B2997B01419BD92F80A 655F3B5C1FB3FA8D1A0CA6BDE4A7D232B936D2FD A363A499291CBBC940DD62E41F10027AF002F8B0'
readonly MICROSOFT_KEY=BC528686B50D79E339D3721CEB3E94ADBE1229CF
readonly TEA_KEY=7C9E68152594688862D62AF62D9AE806EC1592E2

# Treat end of input or anything but yes as refusal.
confirm() {
    local answer
    if ! read -r -p "$1 [y/N] " answer; then
        echo >&2
        warn 'No answer; treating it as no.'
        return 1
    fi
    [[ $answer == [Yy] || $answer == [Yy][Ee][Ss] ]]
}

installed_version() {
    if [[ $(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null || true) == ii* ]]; then
        dpkg-query -W -f='${Version}' "$1"
    fi
}

# Set APT_REQUEST to the packages that are missing or have a newer candidate.
# Requesting only those leaves up-to-date packages' manual/automatic marks alone.
select_apt_packages() {
    local package installed candidate
    APT_REQUEST=()
    for package; do
        [[ -z ${PRESERVED_COMMANDS[$package]:-} ]] || continue
        installed=$(installed_version "$package")
        candidate=$(apt-cache policy "$package" | awk '/Candidate:/ { print $2; exit }')
        if [[ -z $candidate || $candidate == '(none)' ]]; then
            [[ -n $installed ]] && continue
            die "No apt candidate for $package; make it available in the host's apt configuration and rerun. Existing sources were left unchanged."
        fi
        [[ $installed == "$candidate" ]] || APT_REQUEST+=("$package")
    done
}

# Print the installed packages that apt would upgrade or remove while
# installing the arguments, as "upgrade NAME" or "remove NAME".
apt_changes() {
    apt-get -s --no-install-recommends install "$@" | awk '
        $1 == "Inst" && $3 ~ /^\[/ { print "upgrade", $2 }
        $1 == "Remv" { print "remove", $2 }'
}

# Install packages without changing an installed package unless --update or
# the user allows it. Dependency upgrades need the same consent, and a refusal
# holds for the rest of the run.
APT_UPDATES_DECLINED=0
apt_install() {
    (($#)) || return 0
    local changes removals upgrades package new=()
    changes=$(apt_changes "$@")
    removals=$(awk '$1 == "remove" { printf " %s", $2 }' <<< "$changes")
    [[ -z $removals ]] || die "Installing $* would remove$removals; resolve that before installation."
    upgrades=$(awk '$1 == "upgrade" { printf " %s", $2 }' <<< "$changes")
    if [[ -n $upgrades ]] && ((!UPDATE)); then
        [[ -t 0 ]] || die "Existing apt packages have updates available; rerun with --update:$upgrades"
        if ((APT_UPDATES_DECLINED)) || ! confirm "Update$upgrades from their signed apt repositories?"; then
            APT_UPDATES_DECLINED=1
            for package; do
                [[ -n $(installed_version "$package") ]] || new+=("$package")
            done
            ((${#new[@]})) || return 0
            changes=$(apt_changes "${new[@]}")
            [[ -z $changes ]] || die "Installing ${new[*]} requires updating$(awk '{ printf " %s", $2 }' <<< "$changes"); rerun with --update."
            set -- "${new[@]}"
        fi
    fi
    apt-get -y --no-install-recommends install "$@"
}

# The host owns apt's sources, keys, preferences, and configuration. Let apt
# resolve and authenticate packages; do not impose the image's source layout.
apt-get update
select_apt_packages ca-certificates curl gnupg jq xz-utils
apt_install "${APT_REQUEST[@]}"
verify_key_file "$SCRIPT_DIR/microsoft.asc.gpg" "$MICROSOFT_KEY"
verify_key_file "$SCRIPT_DIR/keys/nodejs-release.asc" "$NODE_KEYS"
verify_key_file "$SCRIPT_DIR/keys/teabot.asc" "$TEA_KEY"

# Reuse an installed or available VS Code package. Only provision a repository
# if the host has neither, using dedicated files without changing its sources.
code_candidate=$(apt-cache policy code | awk '/Candidate:/ { print $2; exit }')
if [[ -z ${PRESERVED_COMMANDS[code]:-} && -z $(installed_version code) && ( -z $code_candidate || $code_candidate == '(none)' ) ]]; then
    # apt-config's shell output quotes values for evaluation and /d resolves
    # the effective directory, including APT_CONFIG and Dir overrides.
    source_parts=$APT_DIR/sources.list.d
    source_config=$(apt-config shell source_parts Dir::Etc::sourceparts/d)
    eval "$source_config"
    vscode_source_file=$source_parts/devcarone-host-vscode.list
    vscode_source='deb [arch=amd64 signed-by=/usr/share/keyrings/devcarone-host-microsoft.gpg] https://packages.microsoft.com/repos/code stable main'
    if [[ -e $vscode_source_file || -L $vscode_source_file ]]; then
        [[ -f $vscode_source_file && $(cat "$vscode_source_file") == "$vscode_source" ]] || \
            die "Keeping existing $vscode_source_file; configure an apt candidate for code and rerun."
    fi
    if [[ -e $MICROSOFT_KEYRING || -L $MICROSOFT_KEYRING ]]; then
        cmp -s "$SCRIPT_DIR/microsoft.asc.gpg" "$MICROSOFT_KEYRING" || \
            die "Keeping existing $MICROSOFT_KEYRING; configure an apt candidate for code and rerun."
    else
        install -m 644 "$SCRIPT_DIR/microsoft.asc.gpg" "$MICROSOFT_KEYRING"
    fi
    if [[ ! -e $vscode_source_file ]]; then
        mkdir -p "$source_parts"
        printf '%s\n' "$vscode_source" > "$vscode_source_file"
    fi
    apt-get update
fi

APT_PACKAGES=(
    sudo procps locales lsof file dialog gosu tzdata
    curl wget ca-certificates apt-transport-https gnupg
    net-tools netcat-traditional rsyslog logrotate
    openssh-server rsync xauth tigervnc-standalone-server openbox tint2 feh x11-xserver-utils
    rxvt-unicode pulseaudio mesa-utils vainfo libva2 intel-media-va-driver-non-free libpci3
    fontconfig fonts-dejavu fonts-noto-core fonts-liberation
    vim strace ripgrep jq unzip 7zip xz-utils poppler-utils fonts-noto ffmpeg imagemagick
    pandoc texlive-xetex texlive-latex-base texlive-latex-recommended texlive-latex-extra lmodern
    chromium build-essential git golang-go
    python3 python3-pip python3-venv python3-pytest python3-yaml python3-tomlkit cosign code
)


select_apt_packages "${APT_PACKAGES[@]}"
apt_install "${APT_REQUEST[@]}"
chromium_command=${PRESERVED_COMMANDS[chromium]:-$ROOT/usr/bin/chromium}
# Retire only the stock profile from an earlier managed installation. Custom
# profiles and symlinks belong to the host; never rewrite or source them.
printf '%s\n' 'export PLANNOTATOR_BROWSER=/usr/bin/chromium' \
    'export PLANNOTATOR_REMOTE=0' > "$WORK/stock-plannotator-profile"
RETIRE_PLANNOTATOR_PROFILE=0
if [[ -e $PROFILE_FILE || -L $PROFILE_FILE ]]; then
    if [[ -f $STATE_DIR/plannotator.sha256 && -f $PROFILE_FILE && ! -L $PROFILE_FILE &&
          $(stat -c %u "$PROFILE_FILE") == "$OWNER_UID" ]] &&
        cmp -s "$PROFILE_FILE" "$WORK/stock-plannotator-profile"; then
        RETIRE_PLANNOTATOR_PROFILE=1
    else
        warn "Keeping existing Plannotator profile $PROFILE_FILE; its settings may override launcher defaults."
    fi
fi

# Playwright's "chrome" channel runs /opt/google/chrome/chrome; point it at
# Debian's signed Chromium, as the image does, unless a browser is already there.
chrome_link=$ROOT/opt/google/chrome/chrome
if [[ -L $chrome_link && $(readlink -- "$chrome_link") == "$chromium_command" ]]; then
    :
elif [[ -e $chrome_link || -L $chrome_link ]]; then
    warn "Keeping the existing $chrome_link for Playwright's chrome channel."
else
    mkdir -p "${chrome_link%/*}"
    for chrome_dir in "$ROOT/opt/google" "${chrome_link%/*}"; do
        [[ -d $chrome_dir && ! -L $chrome_dir && $(stat -c %u "$chrome_dir") == "$OWNER_UID" ]] || \
            die "Browser directory is not root-owned: $chrome_dir"
        (( (8#$(stat -c %a "$chrome_dir") & 0022) == 0 )) || \
            die "Browser directory is writable by non-root users: $chrome_dir"
    done
    ln -s -- "$chromium_command" "$chrome_link"
fi

mkdir -p "$BIN_DIR" "$STATE_DIR" "$TOOL_DIR/node" "$TOOL_DIR/npm" "$TOOLING_GENERATIONS"
for secure_dir in "$BIN_DIR" "$ROOT/usr/local/lib" "$STATE_DIR" "$TOOL_DIR" \
    "$TOOL_DIR/node" "$TOOL_DIR/npm" "$ROOT/opt/devcar" "$ROOT/opt/devcar/host-toolchain" \
    "$TOOLING_GENERATIONS"; do
    [[ $(stat -c %u "$secure_dir") == "$OWNER_UID" ]] || die "Install directory is not root-owned: $secure_dir"
    permissions=$(stat -c %a "$secure_dir")
    (( (8#$permissions & 0022) == 0 )) || die "Install directory is writable by non-root users: $secure_dir"
done
for state_file in "$STATE_DIR"/*; do
    [[ -e $state_file ]] || continue
    [[ -f $state_file && ! -L $state_file && $(stat -c %u "$state_file") == "$OWNER_UID" ]] || \
        die "Untrusted state file: $state_file"
    permissions=$(stat -c %a "$state_file")
    (( (8#$permissions & 0022) == 0 )) || die "Writable state file: $state_file"
done
publish_command() {
    local link=$1 expected=$2
    preserve_command "${link##*/}" "$expected" && return 0
    set_link "$link" "$expected"
}
# The tool and tooling generation directories are root-owned and used only by
# this installer, so a link into them is the installer's even when an
# interrupted run left it ahead of the state records.
managed_link_within() {
    local link=$1 directory=$2 target
    if [[ -e $link || -L $link ]]; then
        target=$(readlink -- "$link") || die "Unmanaged install at $link"
        [[ $target == "$directory"/* && $target != */..* ]] || die "Unmanaged install at $link"
    fi
}
set_link() {
    local link=$1 target=$2
    ln -sfn -- "$target" "$link.devcarone-new"
    mv -Tf -- "$link.devcarone-new" "$link"
}
# A managed binary matches its recorded hash, or the pending hash recorded just
# before an interrupted replacement.
managed_binary() {
    local name=$1 binary=$BIN_DIR/$1 hash
    preserve_command "$name" && return 0
    if [[ -e $binary || -L $binary ]]; then
        [[ -f $STATE_DIR/$name.sha256 || -f $STATE_DIR/$name.sha256.new ]] || die "Unmanaged install at $binary"
        [[ -f $binary && ! -L $binary ]] || die "Unexpected managed binary type at $binary"
        hash=$(sha256sum "$binary" | awk '{print $1}')
        [[ $hash == "$(cat "$STATE_DIR/$name.sha256" 2>/dev/null)" || \
           $hash == "$(cat "$STATE_DIR/$name.sha256.new" 2>/dev/null)" ]] || die "Managed binary changed: $binary"
    fi
}
install_managed_binary() {
    local source=$1 name=$2 version=$3 target=$BIN_DIR/$2
    preserve_command "$name" && return 0
    sha256sum "$source" | awk '{print $1}' > "$STATE_DIR/$name.sha256.new"
    install -m 755 -- "$source" "$target.devcarone-new"
    mv -f -- "$target.devcarone-new" "$target"
    printf '%s\n' "$version" > "$STATE_DIR/$name.version"
    mv -f -- "$STATE_DIR/$name.sha256.new" "$STATE_DIR/$name.sha256"
}
# Keep browser defaults local to Plannotator, including non-login launches.
install_plannotator() {
    local source=$1 version=$2 payload launcher=$WORK/plannotator-launcher
    preserve_command plannotator && return 0
    [[ $version =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || die "Invalid Plannotator version $version"
    payload=$TOOL_DIR/plannotator/$version
    mkdir -p "${payload%/*}"
    if [[ $source != "$payload" ]]; then
        install -m 755 -- "$source" "$payload.new"
        mv -f -- "$payload.new" "$payload"
        sha256sum "$payload" | awk '{print $1}' > "$payload.sha256"
    fi
    {
        printf '#!/bin/bash\n# devcarone Plannotator launcher\n'
        printf 'if [[ ! ${PLANNOTATOR_BROWSER+x} ]]; then PLANNOTATOR_BROWSER=%q; fi\n' "$chromium_command"
        printf 'export PLANNOTATOR_BROWSER\nexport PLANNOTATOR_REMOTE=${PLANNOTATOR_REMOTE-0}\n'
        printf 'exec %q "$@"\n' "$payload"
    } > "$launcher"
    install_managed_binary "$launcher" plannotator "$version"
    if ((RETIRE_PLANNOTATOR_PROFILE)) && [[ ! -L $PROFILE_FILE ]] &&
        cmp -s "$PROFILE_FILE" "$WORK/stock-plannotator-profile"; then
        rm -- "$PROFILE_FILE"
        warn 'Removed the old stock Plannotator profile; existing shells retain their environment until restarted or unset.'
    fi
}

# Remove superseded entries of an installer-owned DIRECTORY whose names match
# PATTERN, keeping the named entries: the new one and the one active before
# this run, which agents started earlier may still be using. Unrecognized
# names are left alone, and a failure only warns.
prune_generations() {
    local directory=$1 pattern=$2 entry
    shift 2
    for entry in "$directory"/*; do
        [[ -d $entry && ! -L $entry && ${entry##*/} =~ $pattern ]] || continue
        case " $* " in *" ${entry##*/} "*) continue ;; esac
        rm -rf -- "$entry" || warn "Could not remove superseded $entry"
    done
}
readonly NODE_RELEASE_NAME='^[0-9]+[.][0-9]+[.][0-9]+([.]replaced[.][0-9]+)?$'
readonly GENERATION_NAME='^[0-9]{8}T[0-9]{6}Z-[0-9]+$'

managed_link_within "$TOOL_DIR/current-node" "$TOOL_DIR/node"
managed_link_within "$TOOL_DIR/current-npm" "$TOOL_DIR/npm"
managed_link_within "$TOOLING_DIR" "$TOOLING_GENERATIONS"
managed_binary tea
managed_binary gog
managed_binary plannotator
# Node archives record a non-root owner, which releases extracted by earlier
# installer versions kept. Never run such a tree as root.
untrusted_file() {
    find "$1" ! -type l \( ! -uid "$OWNER_UID" -o -perm /022 \) -print -quit
}
if [[ -L $TOOL_DIR/current-node ]]; then
    active_node=$(readlink -- "$TOOL_DIR/current-node")
    if [[ -d $active_node && -n $(untrusted_file "$active_node") ]]; then
        warn "Non-root accounts can modify $active_node; rerun with --update to replace it."
    fi
fi

INSTALL_MANAGED=1
if [[ -e $STATE_DIR/node-version || -e $STATE_DIR/npm-generation || \
      -e $STATE_DIR/tea.sha256 || -e $STATE_DIR/gog.sha256 || \
      -e $STATE_DIR/plannotator.sha256 || -e $STATE_DIR/tooling-target ]]; then
    if ((UPDATE)); then
        :
    elif [[ -t 0 ]]; then
        confirm 'Update the installed Node, npm agents, tea, gogcli, Plannotator, and skills?' || INSTALL_MANAGED=0
    else
        die 'Managed tools are already installed; rerun with --update in unattended mode.'
    fi
fi
if ((!INSTALL_MANAGED)); then
    for marker in node-version npm-generation tea.sha256 gog.sha256 plannotator.sha256 tooling-target; do
        [[ -z ${PRESERVED_COMMANDS[${marker%.sha256}]:-} ]] || continue
        [[ -f $STATE_DIR/$marker ]] || die "Incomplete managed installation; rerun with --update ($marker missing)."
    done
fi

if ((INSTALL_MANAGED)); then

node_dir=$WORK/node-download
mkdir "$node_dir"
curl -fsSL --retry 3 https://nodejs.org/dist/index.json -o "$node_dir/index.json"
node_version=$(jq -er '[.[] | select(.lts != false)] | .[0].version[1:]' "$node_dir/index.json")
[[ $node_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid latest Node LTS version $node_version"
node_tarball=node-v${node_version}-linux-x64.tar.xz
node_url=https://nodejs.org/dist/v${node_version}
for file in "$node_tarball" SHASUMS256.txt SHASUMS256.txt.sig; do
    curl -fsSL --retry 3 "$node_url/$file" -o "$node_dir/$file"
done
gpg --batch --quiet --import "$SCRIPT_DIR/keys/nodejs-release.asc"
gpg --batch --status-fd 1 --verify "$node_dir/SHASUMS256.txt.sig" "$node_dir/SHASUMS256.txt" \
    > "$node_dir/gpg-status" || die 'Node release manifest signature failed.'
signer=$(awk '$2 == "VALIDSIG" { print $NF }' "$node_dir/gpg-status")
case " $NODE_KEYS " in *" $signer "*) ;; *) die "Unexpected Node signer: $signer" ;; esac
node_hash=$(awk -v file="$node_tarball" '$2 == file { print $1 }' "$node_dir/SHASUMS256.txt")
[[ $node_hash =~ ^[a-fA-F0-9]{64}$ ]] || die 'Node tarball is absent from signed manifest.'
printf '%s  %s\n' "$node_hash" "$node_dir/$node_tarball" | sha256sum -c - >/dev/null || die 'Node tarball hash failed.'
node_stage=$WORK/node-stage
mkdir "$node_stage"
tar --no-same-owner --no-same-permissions -xJf "$node_dir/$node_tarball" -C "$node_stage" --strip-components=1
[[ -x $node_stage/bin/node && -f $node_stage/bin/npm ]] || die 'Node archive has unexpected contents.'

NPM_PACKAGES=(
    @openai/codex @github/copilot opencode-ai @earendil-works/pi-coding-agent
    @anthropic-ai/claude-code firebase-tools @playwright/test
)
npm_stage=$WORK/npm-stage
mkdir "$npm_stage"
export NPM_CONFIG_USERCONFIG=/dev/null NPM_CONFIG_GLOBALCONFIG=/dev/null
export NPM_CONFIG_CACHE=$WORK/npm-cache
PATH=$node_stage/bin:$SYSTEM_PATH "$node_stage/bin/npm" install --prefix "$npm_stage" \
    --registry="$NPM_REGISTRY" --ignore-scripts "${NPM_PACKAGES[@]}"
PATH=$node_stage/bin:$SYSTEM_PATH "$node_stage/bin/npm" audit signatures --prefix "$npm_stage" \
    --registry="$NPM_REGISTRY" || die 'npm registry signature or provenance audit failed.'
PATH=$node_stage/bin:$SYSTEM_PATH "$node_stage/bin/npm" rebuild --prefix "$npm_stage" \
    --registry="$NPM_REGISTRY" @openai/codex @github/copilot opencode-ai \
    @anthropic-ai/claude-code firebase-tools @playwright/test

# Keep the active release when it is intact. Replace an existing directory
# that other accounts could modify or that an interrupted run left inactive.
node_release=$TOOL_DIR/node/$node_version
active_node=$(readlink -- "$TOOL_DIR/current-node" 2>/dev/null || true)
active_npm=$(readlink -- "$TOOL_DIR/current-npm" 2>/dev/null || true)
if [[ ! -e $node_release ]]; then
    mv -- "$node_stage" "$node_release"
elif [[ $node_release != "$active_node" || -n $(untrusted_file "$node_release") ]]; then
    [[ $node_release != "$active_node" ]] || \
        warn "Replacing Node $node_version files that non-root accounts could modify."
    mv -T -- "$node_release" "$node_release.replaced.$$"
    mv -- "$node_stage" "$node_release"
    rm -rf -- "$node_release.replaced.$$"
fi
# Managed npm commands use the verified private Node runtime even when the
# host keeps a different Node version. Launchers belong to their generations.
write_launcher() {
    local destination=$1 command=$2
    {
        printf '#!/bin/bash\n'
        printf 'export PATH=%q:"$PATH"\n' "$node_release/bin"
        printf 'exec %q "$@"\n' "$command"
    } > "$destination"
    chmod 755 "$destination"
}
mkdir -p "$node_release/devcar-bin"
for binary in "$node_release"/bin/*; do
    [[ ${binary##*/} == node ]] && continue
    write_launcher "$node_release/devcar-bin/${binary##*/}" "$binary"
done
npm_generation=$(date -u +%Y%m%dT%H%M%SZ)-$$
mkdir "$npm_stage/bin"
for binary in "$npm_stage"/node_modules/.bin/*; do
    [[ -e $binary || -L $binary ]] || continue
    write_launcher "$npm_stage/bin/${binary##*/}" "$TOOL_DIR/npm/$npm_generation/node_modules/.bin/${binary##*/}"
done
mv -- "$npm_stage" "$TOOL_DIR/npm/$npm_generation"
set_link "$TOOL_DIR/current-node" "$TOOL_DIR/node/$node_version"
set_link "$TOOL_DIR/current-npm" "$TOOL_DIR/npm/$npm_generation"
for binary in "$node_release"/bin/*; do
    name=${binary##*/}
    target=$TOOL_DIR/current-node/devcar-bin/$name
    [[ $name != node ]] || target=$TOOL_DIR/current-node/bin/node
    publish_command "$BIN_DIR/$name" "$target"
done
for binary in "$TOOL_DIR/npm/$npm_generation/bin"/*; do
    publish_command "$BIN_DIR/${binary##*/}" "$TOOL_DIR/current-npm/bin/${binary##*/}"
done
# Remove the installer's command links that no active generation provides,
# including links an interrupted run created. Name records are no longer kept.
for link in "$BIN_DIR"/*; do
    [[ -L $link && ! -e $link ]] || continue
    case $(readlink -- "$link") in
        "$TOOL_DIR/current-node/bin/${link##*/}"|"$TOOL_DIR/current-node/devcar-bin/${link##*/}"|\
        "$TOOL_DIR/current-npm/node_modules/.bin/${link##*/}"|"$TOOL_DIR/current-npm/bin/${link##*/}")
            rm -f -- "$link" ;;
    esac
done
rm -f -- "$STATE_DIR/node-bins" "$STATE_DIR/npm-bins"
printf '%s\n' "$node_version" > "$STATE_DIR/node-version"
printf '%s\n' "$npm_generation" > "$STATE_DIR/npm-generation"
prune_generations "$TOOL_DIR/node" "$NODE_RELEASE_NAME" "$node_version" "${active_node##*/}"
prune_generations "$TOOL_DIR/npm" "$GENERATION_NAME" "$npm_generation" "${active_npm##*/}"

# Metadata selects a release; cryptographic verification below decides whether
# its bytes may be installed. Unavailable metadata or artifacts use the known
# Dockerfile version. An invalid signature, hash, or provenance stops the run.
latest_tag() {
    local url=$1 destination=$2 tag
    if ! curl -fsSL --retry 3 "$url" -o "$destination"; then return 1; fi
    tag=$(jq -er '.tag_name' "$destination") || return 1
    [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s\n' "$tag"
}
select_tag() {
    local name=$1 url=$2 known=$3 target=$4 tag
    if tag=$(latest_tag "$url" "$target"); then
        printf '%s\n' "$tag"
    else
        warn "Could not discover a verifiable latest $name release; using $known."
        printf '%s\n' "$known"
    fi
}
# Succeed, with a warning, when TAG is older than NAME's recorded verified release.
keep_newer() {
    local name=$1 tag=$2 recorded
    [[ -f $STATE_DIR/$name.version ]] || return 1
    recorded=$(cat "$STATE_DIR/$name.version")
    [[ $tag != "$recorded" && $(printf '%s\n%s\n' "$tag" "$recorded" | sort -V | head -n 1) == "$tag" ]] || return 1
    warn "Keeping newer verified $name $recorded."
}
# Run FETCH for TAG, or for KNOWN if TAG's artifacts are unavailable. FETCH
# returns 1 only for unavailable artifacts and stops the run on invalid ones.
# Print the fetched tag, or nothing when a newer verified release is kept.
fetch_release() {
    local name=$1 tag=$2 known=$3 fetch=$4
    keep_newer "$name" "$tag" && return 0
    if "$fetch" "$tag"; then
        printf '%s\n' "$tag"
        return 0
    fi
    [[ $tag != "$known" ]] || die "Could not obtain $name $known."
    warn "Latest $name $tag artifacts are unavailable; using $known."
    keep_newer "$name" "$known" && return 0
    "$fetch" "$known" || die "Could not obtain $name $known."
    printf '%s\n' "$known"
}

fetch_tea() {
    local tag=$1 file
    if [[ $tag != "$TEA_KNOWN" ]] && ! jq -e --arg name "tea-${tag#v}-linux-amd64" \
        '[(.assets // [])[].name] as $names |
            ($names | index($name) != null) and
            ($names | index("checksums.txt") != null) and
            ($names | index("checksums.txt.sig") != null)' "$WORK/tea-release.json" >/dev/null; then
        return 1
    fi
    mkdir -p "$WORK/tea-$tag"
    for file in checksums.txt checksums.txt.sig "tea-${tag#v}-linux-amd64"; do
        curl -fsSL --retry 3 "https://gitea.com/gitea/tea/releases/download/$tag/$file" \
            -o "$WORK/tea-$tag/$file" || return 1
    done
}
if [[ -z ${PRESERVED_COMMANDS[tea]:-} ]]; then
tea_tag=$(select_tag tea https://gitea.com/api/v1/repos/gitea/tea/releases/latest "$TEA_KNOWN" "$WORK/tea-release.json")
tea_tag=$(fetch_release tea "$tea_tag" "$TEA_KNOWN" fetch_tea)
if [[ -n $tea_tag ]]; then
tea_dir=$WORK/tea-$tea_tag
tea_asset=tea-${tea_tag#v}-linux-amd64
gpg --batch --quiet --import "$SCRIPT_DIR/keys/teabot.asc"
gpg --batch --status-fd 1 --verify "$tea_dir/checksums.txt.sig" "$tea_dir/checksums.txt" \
    > "$WORK/tea-gpg-status" || die 'tea checksum signature failed.'
grep -q "^\[GNUPG:\] VALIDSIG .* ${TEA_KEY}\$" "$WORK/tea-gpg-status" || die 'Unexpected tea signer.'
tea_hash=$(awk -v file="$tea_asset" '$2 == file { print $1 }' "$tea_dir/checksums.txt")
[[ $tea_hash =~ ^[a-fA-F0-9]{64}$ ]] || die 'tea asset is absent from its signed checksum list.'
printf '%s  %s\n' "$tea_hash" "$tea_dir/$tea_asset" | sha256sum -c - >/dev/null || die 'tea checksum failed.'
install_managed_binary "$tea_dir/$tea_asset" tea "$tea_tag"
fi
fi

# Download the release binary and its attestations once; the tooling installer
# verifies these same files with cosign before installing them.
fetch_plannotator() {
    local tag=$1 asset=plannotator-linux-x64 directory=$WORK/plannotator-$1 digest status=0
    if [[ $tag != "$PLANNOTATOR_KNOWN" ]]; then
        jq -e --arg name "$asset" '[(.assets // [])[].name] | index($name) != null' \
            "$WORK/plannotator-release.json" >/dev/null || return 1
    fi
    mkdir -p "$directory"
    curl -fsSL --retry 3 \
        "https://github.com/backnotprop/plannotator/releases/download/$tag/$asset" \
        -o "$directory/$asset" || return 1
    digest=$(sha256sum "$directory/$asset" | awk '{print $1}')
    curl -fsSL --retry 3 \
        "https://api.github.com/repos/backnotprop/plannotator/attestations/sha256:$digest" \
        -o "$directory/attestations.json" || return 1
    jq -e '[.attestations[].bundle | select(.dsseEnvelope.payload | @base64d | fromjson
        | .predicateType == "https://slsa.dev/provenance/v1")] | length > 0' \
        "$directory/attestations.json" >/dev/null || status=$?
    # jq -e exits 1 for a false result and higher for unreadable data.
    ((status != 1)) || return 1
    ((status == 0)) || die "Plannotator $tag attestation response is invalid."
}
plannotator_tag=$(select_tag plannotator https://api.github.com/repos/backnotprop/plannotator/releases/latest \
    "$PLANNOTATOR_KNOWN" "$WORK/plannotator-release.json")
plannotator_tag=$(fetch_release plannotator "$plannotator_tag" "$PLANNOTATOR_KNOWN" fetch_plannotator)
if [[ -n $plannotator_tag ]]; then
tooling_stage=$WORK/tooling-stage
mkdir "$tooling_stage"
matt_commit_json=$WORK/matt-commit.json
curl -fsSL --retry 3 https://api.github.com/repos/mattpocock/skills/commits/main -o "$matt_commit_json"
matt_commit=$(jq -er .sha "$matt_commit_json")
[[ $matt_commit =~ ^[a-fA-F0-9]{40}$ ]] || die 'Invalid Matt Pocock commit ID.'
bash "$SCRIPT_DIR/install-tooling.sh" "$matt_commit" "$plannotator_tag" "$tooling_stage" \
    "$WORK/plannotator-$plannotator_tag"
tooling_generation=$(date -u +%Y%m%dT%H%M%SZ)-$$
tooling_target=$TOOLING_GENERATIONS/$tooling_generation
active_tooling=$(readlink -- "$TOOLING_DIR" 2>/dev/null || true)
mv -- "$tooling_stage/opt/devcar/tooling" "$tooling_target"
set_link "$TOOLING_DIR" "$tooling_target"
printf '%s\n' "$tooling_target" > "$STATE_DIR/tooling-target"
prune_generations "$TOOLING_GENERATIONS" "$GENERATION_NAME" "$tooling_generation" "${active_tooling##*/}"
install_plannotator "$tooling_stage/usr/local/bin/plannotator" "$plannotator_tag"
elif [[ -z ${PRESERVED_COMMANDS[plannotator]:-} ]]; then
    # A fallback can retain a newer release. Migrate its old direct binary too.
    retained_version=$(cat "$STATE_DIR/plannotator.version")
    [[ $retained_version =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || die 'Invalid recorded Plannotator version.'
    retained_payload=$TOOL_DIR/plannotator/$retained_version
    if [[ -f $retained_payload ]]; then
        [[ $(sha256sum "$retained_payload" | awk '{print $1}') == "$(cat "$retained_payload.sha256")" ]] || \
            die 'Managed Plannotator payload changed.'
    else
        if grep -q '^# devcarone Plannotator launcher$' "$BIN_DIR/plannotator"; then
            die "Missing managed Plannotator payload $retained_payload"
        fi
        retained_payload=$BIN_DIR/plannotator
    fi
    install_plannotator "$retained_payload" "$retained_version"
fi

if [[ -z ${PRESERVED_COMMANDS[gog]:-} ]]; then
gog_tag=$(select_tag gogcli https://api.github.com/repos/openclaw/gogcli/releases/latest \
    "$GOG_KNOWN" "$WORK/gog-release.json")
mkdir "$WORK/go" "$WORK/go-cache" "$WORK/go-bin"
proxy_token=$(od -An -N24 -tx1 /dev/urandom | tr -d '[:space:]')
DEVCAR_GO_PROXY_TOKEN=$proxy_token python3 "$SCRIPT_DIR/go-ipv4-proxy.py" \
    "$WORK/go-proxy-port" &
GO_PROXY_PID=$!
for ((attempt=0; attempt<50; attempt++)); do
    [[ -s $WORK/go-proxy-port ]] && break
    kill -0 "$GO_PROXY_PID" 2>/dev/null || die 'IPv4 proxy stopped before becoming ready.'
    sleep 0.1
done
[[ -s $WORK/go-proxy-port ]] || die 'IPv4 proxy did not become ready.'
proxy_port=$(cat "$WORK/go-proxy-port")
[[ $proxy_port =~ ^[0-9]+$ ]] || die 'IPv4 proxy returned an invalid port.'
proxy_url=http://go:$proxy_token@127.0.0.1:$proxy_port
# Go's checksum database verifies the module; a missing release is unavailable,
# any other failure stops the run.
fetch_gog() {
    GOPATH=$WORK/go GOCACHE=$WORK/go-cache GOBIN=$WORK/go-bin \
        GOTOOLCHAIN=auto GOSUMDB=sum.golang.org GOPROXY=https://proxy.golang.org \
        GONOSUMDB= GOPRIVATE= GONOPROXY= GOINSECURE= GOFLAGS=-modcacherw \
        HTTPS_PROXY=$proxy_url https_proxy=$proxy_url HTTP_PROXY= http_proxy= \
        NO_PROXY= no_proxy= go install "github.com/openclaw/gogcli/cmd/gog@$1" \
        2> "$WORK/gog-error" && return 0
    sed "s/$proxy_token/<REDACTED>/g" "$WORK/gog-error" >&2
    grep -Eq 'unknown revision|404 Not Found' "$WORK/gog-error" && return 1
    die "gogcli $1 Go checksum database or build failed."
}
gog_tag=$(fetch_release gog "$gog_tag" "$GOG_KNOWN" fetch_gog)
if [[ -n $gog_tag ]]; then
install_managed_binary "$WORK/go-bin/gog" gog "$gog_tag"
fi
kill "$GO_PROXY_PID" 2>/dev/null || true
wait "$GO_PROXY_PID" 2>/dev/null || true
GO_PROXY_PID=
fi
fi

if [[ -n $TARGET_USER ]]; then
    user_home=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    user_shell=$(getent passwd "$TARGET_USER" | cut -d: -f7)
    [[ -d $user_home ]] || die "Home directory does not exist for $TARGET_USER"
    as_user=(gosu "$TARGET_USER" env HOME="$user_home" USER="$TARGET_USER"
        LOGNAME="$TARGET_USER" SHELL="$user_shell")
    "${as_user[@]}" CODEX_HOME="$user_home/.codex" python3 "$SCRIPT_DIR/configure-codex.py"
    "${as_user[@]}" CLAUDE_CONFIG_DIR="$user_home/.claude" python3 "$SCRIPT_DIR/configure-claude.py"
    DEVCAR_TOOLING=$TOOLING_DIR bash "$SCRIPT_DIR/link-skills.sh" "$ROOT/etc/codex/skills" on
    "${as_user[@]}" DEVCAR_TOOLING="$TOOLING_DIR" \
        bash "$SCRIPT_DIR/link-skills.sh" "$user_home/.claude/skills" on
else
    echo 'System tools installed. Run again with --user NAME to configure agent hooks and skills.'
fi
echo 'Verified host toolchain installation complete.'
