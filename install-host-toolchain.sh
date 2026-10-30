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
readonly MICROSOFT_KEYRING=$ROOT/usr/share/keyrings/microsoft.asc.gpg
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
for command_name in node npm codex copilot opencode pi claude firebase playwright tea gog plannotator; do
    command_path=$(command -v "$command_name" || true)
    if [[ -n $command_path && $command_path != $BIN_DIR/$command_name ]]; then
        die "Unmanaged $command_name command is already on PATH at $command_path"
    fi
    if [[ $command_path == $BIN_DIR/$command_name && ! -d $STATE_DIR ]]; then
        die "Unmanaged $command_name command is already installed at $command_path"
    fi
done
for command_name in code chromium; do
    command_path=$(command -v "$command_name" || true)
    if [[ -n $command_path && $command_path != $ROOT/usr/bin/$command_name && \
          $command_path != $ROOT/bin/$command_name ]]; then
        die "Unmanaged $command_name command is already on PATH at $command_path"
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

readonly DEBIAN_KEYS='04B54C3CDCA79751B16BC6B5225629DF75B188BD 5E04A1E3223A19A20706E20F9904613D4CCE68C6 41587F7DB8C774BCCF131416762F67A0B2C39DE4 B8B80B5B623EAB6AD8775C45B7C5D7D6350947F8 05AB90340C0C5E797F44A8C8254CF3B5AEC0A8F0 4D64FEC119C2029067D6E791F8D2585B8783D481 1F89983E0081FDE018F3CC9673A4F27B8DD47936 AC530D520F2F3269F5E98313A48449044AAD5C5D A4285295FC7B1A81600062A9605C66F00D6C9793'
readonly NODE_KEYS='5BE8A3F6C8A5C01D106C0AD820B1A390B168D356 DD792F5973C6DE52C432CBDAC77ABFA00DDBF2B7 CC68F5A3106FF448322E48ED27F5E38D5B0A215F 890C08DB8579162FEE0DF9DB8BEAB4DFCF555EF4 C82FA3AE1CBEDC6BE46B9360C43CEC45C17AB93C 108F52B48DB57BB0CC439B2997B01419BD92F80A 655F3B5C1FB3FA8D1A0CA6BDE4A7D232B936D2FD A363A499291CBBC940DD62E41F10027AF002F8B0'
readonly MICROSOFT_KEY=BC528686B50D79E339D3721CEB3E94ADBE1229CF
readonly TEA_KEY=7C9E68152594688862D62AF62D9AE806EC1592E2

# Apt authenticates the bootstrap packages before gpg/jq are available, so the
# whole apt configuration is checked before any of it changes or apt runs.
readonly DEBIAN_SOURCES=$APT_DIR/sources.list.d/debian.sources
readonly VSCODE_SOURCES=$APT_DIR/sources.list.d/vscode.list
# Bracket expressions keep these patterns intact when passed through awk -v.
readonly DEBIAN_ARCHIVE_URI='^https?://deb[.]debian[.]org/debian/?$'
readonly DEBIAN_ARCHIVE_SUITES='^trixie(-updates|-backports)?$'
readonly DEBIAN_SECURITY_URI='^https?://security[.]debian[.]org/debian-security/?$'
readonly DEBIAN_SECURITY_SUITES='^trixie-security$'
readonly DEBIAN_KEYRING_PATHS='^/usr/share/keyrings/debian-archive-keyring[.](pgp|gpg)$'
readonly DEBIAN_COMPONENTS='main contrib non-free non-free-firmware'

# Print each active stanza's keyring, or the first problem and fail. Only plain
# fields are accepted, so options such as Trusted or Allow-Insecure are refused.
debian_source_keyrings() {
    awk -v archive_uri="$DEBIAN_ARCHIVE_URI" -v archive_suites="$DEBIAN_ARCHIVE_SUITES" \
        -v security_uri="$DEBIAN_SECURITY_URI" -v security_suites="$DEBIAN_SECURITY_SUITES" \
        -v keyring_paths="$DEBIAN_KEYRING_PATHS" '
        function fail(message) { print message; failed = 1; exit 1 }
        function check(   key, i, j, uri_count, suite_count, uris, suites, types, suite_pattern) {
            if (!fields) return
            fields = 0
            if (tolower(field["enabled"]) == "no") { split("", field); return }
            for (key in field)
                if (index(" types uris suites components signed-by enabled architectures ", " " key " ") == 0)
                    fail("unsupported option " key)
            if (field["enabled"] != "" && tolower(field["enabled"]) != "yes") fail("unsupported Enabled value")
            if (!split(field["types"], types, " ")) fail("missing Types")
            for (i in types) if (types[i] != "deb" && types[i] != "deb-src") fail("unsupported type " types[i])
            if (field["signed-by"] !~ keyring_paths) fail("Signed-By must name the Debian archive keyring")
            if (field["components"] == "") fail("missing Components")
            uri_count = split(field["uris"], uris, " ")
            suite_count = split(field["suites"], suites, " ")
            if (!uri_count || !suite_count) fail("missing URIs or Suites")
            for (i = 1; i <= uri_count; i++) {
                if (uris[i] ~ archive_uri) suite_pattern = archive_suites
                else if (uris[i] ~ security_uri) suite_pattern = security_suites
                else fail("unexpected repository URI " uris[i])
                for (j = 1; j <= suite_count; j++)
                    if (suites[j] !~ suite_pattern) fail("unexpected suite " suites[j] " for " uris[i])
            }
            if (!(field["signed-by"] in keyrings)) { keyrings[field["signed-by"]] = 1; count++ }
            split("", field)
        }
        /^#/ { next }
        /^[ \t]*$/ { check(); next }
        /^[ \t]/ { if (!fields) fail("malformed continuation line"); field[name] = field[name] "\n" $0; next }
        {
            separator = index($0, ":")
            if (!separator) fail("malformed line")
            name = tolower(substr($0, 1, separator - 1))
            if (name in field) fail("duplicate field " name)
            value = substr($0, separator + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", value)
            field[name] = value
            fields++
        }
        END {
            if (failed) exit 1
            check()
            if (!count) fail("no active Debian source")
            for (key in keyrings) print key
        }' "$1"
}

# Print the first apt setting that weakens authentication or moves the source
# lists elsewhere.
apt_config_problem() {
    apt-config dump | awk '
        { key = tolower($1); value = $2; gsub(/^"|";?$/, "", value); value = tolower(value) }
        key ~ /(^|::)(allowinsecurerepositories|allowdowngradetoinsecurerepositories|allowweakrepositories|allowunauthenticated)$/ &&
            value !~ /^(false|no|off|0|disable|without)$/ { print $1; exit }
        (key == "dir" && value != "/") ||
            (key == "dir::etc" && value != "etc/apt/" && value != "etc/apt") ||
            (key == "dir::etc::sourcelist" && value != "sources.list") ||
            (key == "dir::etc::sourceparts" && value != "sources.list.d") { print $1; exit }'
}

# Add any missing required component to each active stanza, keeping the
# existing components, their order, and every other line.
enable_debian_components() {
    awk -v required="$DEBIAN_COMPONENTS" '
        function flush(   i, j, line, list, have, wanted, n) {
            for (i = 1; i <= count; i++) {
                line = lines[i]
                if (active && tolower(line) ~ /^components:/) {
                    n = split(substr(line, index(line, ":") + 1), list, " ")
                    split("", have)
                    for (j = 1; j <= n; j++) have[list[j]] = 1
                    sub(/[ \t]+$/, "", line)
                    n = split(required, wanted, " ")
                    for (j = 1; j <= n; j++) if (!(wanted[j] in have)) line = line " " wanted[j]
                }
                print line
            }
            count = 0
            active = 1
        }
        BEGIN { active = 1 }
        /^[ \t]*$/ { flush(); print; next }
        { lines[++count] = $0; if (tolower($0) ~ /^enabled:[ \t]*no[ \t]*$/) active = 0 }
        END { flush() }' "$1"
}

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

# A matching name is not enough: the installed version must exist in the
# expected signed apt repository. Debian packages may already be in a base OS.
apt_origin_ok() {
    local package=$1 version=$2 code=0
    [[ $package != code ]] || code=1
    apt-cache policy "$package" | awk -v version="$version" -v code="$code" \
        -v archive_uri="$DEBIAN_ARCHIVE_URI" -v archive_suites="$DEBIAN_ARCHIVE_SUITES" \
        -v security_uri="$DEBIAN_SECURITY_URI" -v security_suites="$DEBIAN_SECURITY_SUITES" '
        $1 == "***" && $2 == version { in_version = 1; next }
        $1 == version { in_version = 1; next }
        in_version && /^     [^ ]/ { in_version = 0 }
        in_version {
            suite = $3
            sub(/\/.*/, "", suite)
            if (code) {
                if ($2 ~ /^https:\/\/packages[.]microsoft[.]com\/repos\/code\/?$/ && suite == "stable") found = 1
            } else if (($2 ~ archive_uri && suite ~ archive_suites) ||
                       ($2 ~ security_uri && suite ~ security_suites)) {
                found = 1
            }
        }
        END { exit !found }
    '
}

# Set APT_REQUEST to the packages that are missing or have a newer candidate.
# Requesting only those leaves up-to-date packages' manual/automatic marks alone.
select_apt_packages() {
    local package installed candidate
    APT_REQUEST=()
    for package; do
        installed=$(installed_version "$package")
        candidate=$(apt-cache policy "$package" | awk '/Candidate:/ { print $2; exit }')
        [[ -n $candidate && $candidate != '(none)' ]] || die "No signed apt candidate for $package"
        if [[ -z $installed ]]; then
            APT_REQUEST+=("$package")
        else
            apt_origin_ok "$package" "$installed" || die "$package $installed is not attributable to its expected apt repository."
            [[ $installed == "$candidate" ]] || APT_REQUEST+=("$package")
        fi
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

unset APT_CONFIG
[[ -f $DEBIAN_SOURCES ]] || die "Missing standard Debian source file $DEBIAN_SOURCES"
if [[ -s $APT_DIR/sources.list ]]; then
    die "Additional apt sources in $APT_DIR/sources.list need review before installation."
fi
for source_file in "$APT_DIR"/sources.list.d/*.list "$APT_DIR"/sources.list.d/*.sources; do
    [[ -e $source_file ]] || continue
    [[ $source_file == "$DEBIAN_SOURCES" || $source_file == "$VSCODE_SOURCES" ]] || \
        die "Additional apt source needs review: $source_file"
done
debian_keyrings=$(debian_source_keyrings "$DEBIAN_SOURCES") || \
    die "Debian source needs review: $debian_keyrings"
for keyring in $debian_keyrings; do
    [[ -f $ROOT$keyring ]] || die "Missing Debian archive keyring $keyring"
done
apt_problem=$(apt_config_problem)
[[ -z $apt_problem ]] || die "Apt setting $apt_problem needs review before installation."
vscode_source='deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.asc.gpg] https://packages.microsoft.com/repos/code stable main'
if [[ -e $VSCODE_SOURCES ]]; then
    [[ $(cat "$VSCODE_SOURCES") == "$vscode_source" ]] || \
        die 'Existing VS Code apt source differs from the expected signed repository.'
    [[ -f $MICROSOFT_KEYRING ]] && \
        cmp -s "$SCRIPT_DIR/microsoft.asc.gpg" "$MICROSOFT_KEYRING" || \
        die 'Existing Microsoft apt key differs from the trusted bundle.'
fi
vscode_pins=$'Package: code\nPin: origin packages.microsoft.com\nPin-Priority: 600\n\nPackage: *\nPin: origin packages.microsoft.com\nPin-Priority: -1'
if [[ -e $APT_DIR/preferences.d/devcarone-host-toolchain ]] && \
    [[ $(cat "$APT_DIR/preferences.d/devcarone-host-toolchain") != "$vscode_pins" ]]; then
    die 'Existing VS Code apt preferences differ from the installer policy.'
fi

printf '%s\n' "$vscode_pins" > "$APT_DIR/preferences.d/devcarone-host-toolchain"
enable_debian_components "$DEBIAN_SOURCES" > "$DEBIAN_SOURCES.devcarone.$$"
if cmp -s "$DEBIAN_SOURCES.devcarone.$$" "$DEBIAN_SOURCES"; then
    rm -- "$DEBIAN_SOURCES.devcarone.$$"
else
    chmod --reference="$DEBIAN_SOURCES" -- "$DEBIAN_SOURCES.devcarone.$$"
    chown --reference="$DEBIAN_SOURCES" -- "$DEBIAN_SOURCES.devcarone.$$"
    mv -f -- "$DEBIAN_SOURCES.devcarone.$$" "$DEBIAN_SOURCES"
fi
apt-get update
select_apt_packages ca-certificates curl gnupg jq xz-utils
apt_install "${APT_REQUEST[@]}"
for keyring in $debian_keyrings; do
    verify_key_file "$ROOT$keyring" "$DEBIAN_KEYS"
done
verify_key_file "$SCRIPT_DIR/microsoft.asc.gpg" "$MICROSOFT_KEY"
verify_key_file "$SCRIPT_DIR/keys/nodejs-release.asc" "$NODE_KEYS"
verify_key_file "$SCRIPT_DIR/keys/teabot.asc" "$TEA_KEY"

install -m 644 "$SCRIPT_DIR/microsoft.asc.gpg" "$MICROSOFT_KEYRING"
printf '%s\n' "$vscode_source" > "$VSCODE_SOURCES"
apt-get update

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
plannotator_profile=$'export PLANNOTATOR_BROWSER=/usr/bin/chromium\nexport PLANNOTATOR_REMOTE=0'
if [[ -e "$PROFILE_FILE" ]] && \
    [[ $(cat "$PROFILE_FILE") != "$plannotator_profile" ]]; then
    die 'Existing Plannotator environment profile differs from the installer policy.'
fi
printf '%s\n' "$plannotator_profile" > "$PROFILE_FILE"

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
managed_link() {
    local link=$1 expected=$2
    if [[ -e $link || -L $link ]]; then
        [[ -L $link && $(readlink -- "$link") == "$expected" ]] || die "Unmanaged install at $link"
    fi
}
set_link() {
    local link=$1 target=$2 temporary
    temporary=$link.new.$$
    ln -s -- "$target" "$temporary"
    mv -Tf -- "$temporary" "$link"
}
managed_binary() {
    local binary=$1 marker=$2
    if [[ -e $binary || -L $binary ]]; then
        [[ -f $marker ]] || die "Unmanaged install at $binary"
        [[ -f $binary && ! -L $binary ]] || die "Unexpected managed binary type at $binary"
        printf '%s  %s\n' "$(cat "$marker")" "$binary" | sha256sum -c - >/dev/null || die "Managed binary changed: $binary"
    fi
}

for name in node npm npx corepack; do
    managed_link "$BIN_DIR/$name" "$TOOL_DIR/current-node/bin/$name"
done
managed_link "$TOOL_DIR/current-node" "${TOOL_DIR}/node/$(cat "$STATE_DIR/node-version" 2>/dev/null || true)"
managed_link "$TOOL_DIR/current-npm" "${TOOL_DIR}/npm/$(cat "$STATE_DIR/npm-generation" 2>/dev/null || true)"
managed_link "$TOOLING_DIR" "$(cat "$STATE_DIR/tooling-target" 2>/dev/null || true)"
for kind in node npm; do
    if [[ -f $STATE_DIR/$kind-bins ]]; then
        while IFS= read -r name; do
            [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid recorded $kind command name."
            if [[ $kind == node ]]; then
                managed_link "$BIN_DIR/$name" "$TOOL_DIR/current-node/bin/$name"
            else
                managed_link "$BIN_DIR/$name" "$TOOL_DIR/current-npm/node_modules/.bin/$name"
            fi
        done < "$STATE_DIR/$kind-bins"
    fi
done
managed_binary "$BIN_DIR/tea" "$STATE_DIR/tea.sha256"
managed_binary "$BIN_DIR/gog" "$STATE_DIR/gog.sha256"
managed_binary "$BIN_DIR/plannotator" "$STATE_DIR/plannotator.sha256"
# Node archives record a non-root owner, which releases extracted by earlier
# installer versions kept. Never run such a tree as root.
untrusted_file() {
    find "$1" ! -type l \( ! -uid "$OWNER_UID" -o -perm /022 \) -print -quit
}
if [[ -f $STATE_DIR/node-version ]]; then
    recorded_node=$TOOL_DIR/node/$(cat "$STATE_DIR/node-version")
    if [[ -d $recorded_node && -n $(untrusted_file "$recorded_node") ]]; then
        warn "Non-root accounts can modify $recorded_node; rerun with --update to replace it."
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
for binary in "$npm_stage"/node_modules/.bin/*; do
    [[ -e $binary || -L $binary ]] || continue
    name=${binary##*/}
    managed_link "$BIN_DIR/$name" "$TOOL_DIR/current-npm/node_modules/.bin/$name"
done
PATH=$node_stage/bin:$SYSTEM_PATH "$node_stage/bin/npm" rebuild --prefix "$npm_stage" \
    --registry="$NPM_REGISTRY" @openai/codex @github/copilot opencode-ai \
    @anthropic-ai/claude-code firebase-tools @playwright/test

for binary in "$npm_stage"/node_modules/.bin/*; do
    [[ -e $binary || -L $binary ]] || continue
    name=${binary##*/}
    managed_link "$BIN_DIR/$name" "$TOOL_DIR/current-npm/node_modules/.bin/$name"
done
for binary in "$node_stage"/bin/*; do
    name=${binary##*/}
    managed_link "$BIN_DIR/$name" "$TOOL_DIR/current-node/bin/$name"
done

node_release=$TOOL_DIR/node/$node_version
if [[ -e $node_release ]]; then
    [[ -f $STATE_DIR/node-version && $(cat "$STATE_DIR/node-version") == "$node_version" ]] || die 'Unmanaged Node release directory exists.'
    if [[ -n $(untrusted_file "$node_release") ]]; then
        warn "Replacing Node $node_version files that non-root accounts could modify."
        mv -T -- "$node_release" "$node_release.untrusted.$$"
        mv -- "$node_stage" "$node_release"
        rm -rf -- "$node_release.untrusted.$$"
    fi
else
    mv -- "$node_stage" "$node_release"
fi
npm_generation=$(date -u +%Y%m%dT%H%M%SZ)-$$
mv -- "$npm_stage" "$TOOL_DIR/npm/$npm_generation"
set_link "$TOOL_DIR/current-node" "$TOOL_DIR/node/$node_version"
set_link "$TOOL_DIR/current-npm" "$TOOL_DIR/npm/$npm_generation"
for binary in "$TOOL_DIR/node/$node_version"/bin/*; do
    set_link "$BIN_DIR/${binary##*/}" "$TOOL_DIR/current-node/bin/${binary##*/}"
done
for binary in "$TOOL_DIR/npm/$npm_generation"/node_modules/.bin/*; do
    set_link "$BIN_DIR/${binary##*/}" "$TOOL_DIR/current-npm/node_modules/.bin/${binary##*/}"
done
for kind in node npm; do
    if [[ $kind == node ]]; then search_dir=$TOOL_DIR/node/$node_version/bin
    else search_dir=$TOOL_DIR/npm/$npm_generation/node_modules/.bin; fi
    new_names=$WORK/$kind-bins
    : > "$new_names"
    for binary in "$search_dir"/*; do
        [[ -e $binary || -L $binary ]] || continue
        printf '%s\n' "${binary##*/}" >> "$new_names"
    done
    if [[ -f $STATE_DIR/$kind-bins ]]; then
        while IFS= read -r old_name; do
            if ! grep -Fxq -- "$old_name" "$new_names"; then
                rm -- "$BIN_DIR/$old_name"
            fi
        done < "$STATE_DIR/$kind-bins"
    fi
    install -m 644 "$new_names" "$STATE_DIR/$kind-bins"
done
printf '%s\n' "$node_version" > "$STATE_DIR/node-version"
printf '%s\n' "$npm_generation" > "$STATE_DIR/npm-generation"
PATH=$BIN_DIR:$SYSTEM_PATH npm cache clean --force

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
install -m 755 "$tea_dir/$tea_asset" "$BIN_DIR/tea"
sha256sum "$BIN_DIR/tea" | awk '{print $1}' > "$STATE_DIR/tea.sha256"
printf '%s\n' "$tea_tag" > "$STATE_DIR/tea.version"
fi

# The tooling installer downloads and verifies the known release itself; a newer
# release must first show that its Linux binary and SLSA provenance exist.
fetch_plannotator() {
    local tag=$1 asset=plannotator-linux-x64 digest status=0
    [[ $tag != "$PLANNOTATOR_KNOWN" ]] || return 0
    jq -e --arg name "$asset" '[(.assets // [])[].name] | index($name) != null' \
        "$WORK/plannotator-release.json" >/dev/null || return 1
    curl -fsSL --retry 3 \
        "https://github.com/backnotprop/plannotator/releases/download/$tag/$asset" \
        -o "$WORK/plannotator-probe" || return 1
    digest=$(sha256sum "$WORK/plannotator-probe" | awk '{print $1}')
    curl -fsSL --retry 3 \
        "https://api.github.com/repos/backnotprop/plannotator/attestations/sha256:$digest" \
        -o "$WORK/plannotator-probe-attestations.json" || return 1
    jq -e '[.attestations[].bundle | select(.dsseEnvelope.payload | @base64d | fromjson
        | .predicateType == "https://slsa.dev/provenance/v1")] | length > 0' \
        "$WORK/plannotator-probe-attestations.json" >/dev/null || status=$?
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
bash "$SCRIPT_DIR/install-tooling.sh" "$matt_commit" "$plannotator_tag" "$tooling_stage"
tooling_generation=$(date -u +%Y%m%dT%H%M%SZ)-$$
tooling_target=$TOOLING_GENERATIONS/$tooling_generation
mv -- "$tooling_stage/opt/devcar/tooling" "$tooling_target"
install -m 755 "$tooling_stage/usr/local/bin/plannotator" "$BIN_DIR/plannotator"
sha256sum "$BIN_DIR/plannotator" | awk '{print $1}' > "$STATE_DIR/plannotator.sha256"
set_link "$TOOLING_DIR" "$tooling_target"
printf '%s\n' "$tooling_target" > "$STATE_DIR/tooling-target"
printf '%s\n' "$plannotator_tag" > "$STATE_DIR/plannotator.version"
fi

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
install -m 755 "$WORK/go-bin/gog" "$BIN_DIR/gog"
sha256sum "$BIN_DIR/gog" | awk '{print $1}' > "$STATE_DIR/gog.sha256"
printf '%s\n' "$gog_tag" > "$STATE_DIR/gog.version"
fi
kill "$GO_PROXY_PID" 2>/dev/null || true
wait "$GO_PROXY_PID" 2>/dev/null || true
GO_PROXY_PID=
fi

if [[ -n $TARGET_USER ]]; then
    user_home=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    user_shell=$(getent passwd "$TARGET_USER" | cut -d: -f7)
    [[ -d $user_home ]] || die "Home directory does not exist for $TARGET_USER"
    gosu "$TARGET_USER" env HOME="$user_home" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
        SHELL="$user_shell" CODEX_HOME="$user_home/.codex" \
        python3 "$SCRIPT_DIR/configure-codex.py"
    gosu "$TARGET_USER" env HOME="$user_home" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
        SHELL="$user_shell" CLAUDE_CONFIG_DIR="$user_home/.claude" \
        python3 "$SCRIPT_DIR/configure-claude.py"
    DEVCAR_TOOLING=$TOOLING_DIR bash "$SCRIPT_DIR/link-skills.sh" "$ROOT/etc/codex/skills" on
    gosu "$TARGET_USER" env HOME="$user_home" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
        SHELL="$user_shell" DEVCAR_TOOLING="$TOOLING_DIR" \
        bash "$SCRIPT_DIR/link-skills.sh" "$user_home/.claude/skills" on
else
    echo 'System tools installed. Run again with --user NAME to configure agent hooks and skills.'
fi
echo 'Verified host toolchain installation complete.'
