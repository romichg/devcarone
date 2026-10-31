#!/usr/bin/env bash
# Build-time install. Optional third argument stages an installation for testing.
# An optional fourth names a directory already holding the release binary and its
# attestations.json; they are verified exactly as downloaded ones would be.
set -euo pipefail
MATT_REF=${1:?Matt Pocock commit or branch required}
PLANNOTATOR_VERSION=${2:?Plannotator release tag required}
DEST=${3:-}
DOWNLOADED=${4:-}
SOURCE_DIR=$DEST/opt/devcar/tooling
BIN_DIR=$DEST/usr/local/bin
TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEMP_DIR"' EXIT

checkout() {
    local repo=$1 ref=$2 target=$3
    shift 3
    git init -q "$target"
    git -C "$target" remote add origin "https://github.com/$repo.git"
    git -C "$target" config core.sparseCheckout true
    printf '%s\n' "$@" > "$target/.git/info/sparse-checkout"
    git -C "$target" fetch -q --depth=1 --filter=blob:none origin "$ref"
    git -C "$target" checkout -q FETCH_HEAD
}

mkdir -p "$SOURCE_DIR" "$BIN_DIR"
checkout mattpocock/skills "$MATT_REF" "$TEMP_DIR/matt" /skills/ /LICENSE \
    /.claude-plugin/plugin.json
cp -a "$TEMP_DIR/matt/skills" "$SOURCE_DIR/matt-pocock"
cp "$TEMP_DIR/matt/LICENSE" "$SOURCE_DIR/matt-pocock-LICENSE"
checkout backnotprop/plannotator "$PLANNOTATOR_VERSION" "$TEMP_DIR/plannotator" \
    /apps/skills/core/ /LICENSE-MIT /LICENSE-APACHE
cp -a "$TEMP_DIR/plannotator/apps/skills/core" "$SOURCE_DIR/plannotator"
cp "$TEMP_DIR/plannotator/"LICENSE-* "$SOURCE_DIR/"

# Startup links these skills for each agent (link-skills.sh); upstream trees stay
# intact for relative references. Matt's Claude plugin manifest is his curated
# set, which leaves out in-progress and personal skills.
SKILLS_LIST=$SOURCE_DIR/skills.list
{
    jq -r '.skills[]' "$TEMP_DIR/matt/.claude-plugin/plugin.json" | while IFS= read -r path; do
        if [[ $path != ./skills/* ]]; then
            echo "Unexpected skill path in Matt Pocock's plugin.json: $path" >&2
            exit 1
        fi
        printf 'matt-pocock/%s\n' "${path#./skills/}"
    done
    (cd "$SOURCE_DIR" && find plannotator -name SKILL.md -printf '%h\n' | sort)
} > "$SKILLS_LIST"
while IFS= read -r skill; do
    if [[ ! -f $SOURCE_DIR/$skill/SKILL.md ]]; then
        echo "Listed skill has no SKILL.md: $skill" >&2
        exit 1
    fi
done < "$SKILLS_LIST"
duplicates=$(sed 's|.*/||' "$SKILLS_LIST" | sort | uniq -d)
if [[ -n $duplicates ]]; then
    echo "Duplicate skill names: $duplicates" >&2
    exit 1
fi

case $(uname -m) in
    x86_64) asset=plannotator-linux-x64 ;;
    aarch64|arm64) asset=plannotator-linux-arm64 ;;
    *) echo 'Unsupported Plannotator architecture.' >&2; exit 1 ;;
esac
# Plannotator publishes no GPG signatures, but GitHub records Sigstore SLSA
# provenance for each release binary. Require the provenance to come from the
# release workflow run for this exact tag.
if [[ -n $DOWNLOADED ]]; then
    cp -- "$DOWNLOADED/$asset" "$DOWNLOADED/attestations.json" "$TEMP_DIR/"
else
    release_url=https://github.com/backnotprop/plannotator/releases/download/$PLANNOTATOR_VERSION
    curl --fail --location --silent --show-error --retry 3 "$release_url/$asset" -o "$TEMP_DIR/$asset"
    digest=$(sha256sum "$TEMP_DIR/$asset" | cut -d' ' -f1)
    curl --fail --location --silent --show-error --retry 3 \
        "https://api.github.com/repos/backnotprop/plannotator/attestations/sha256:$digest" \
        -o "$TEMP_DIR/attestations.json"
fi
jq -e '[.attestations[].bundle | select(.dsseEnvelope.payload | @base64d | fromjson
        | .predicateType == "https://slsa.dev/provenance/v1")][0]' \
    "$TEMP_DIR/attestations.json" > "$TEMP_DIR/provenance.json"
# The binary is larger than cosign's default 128 MiB limit. The temporary HOME
# keeps cosign's Sigstore trust root cache out of the builder's home directory.
HOME=$TEMP_DIR COSIGN_MAX_ATTACHMENT_SIZE=512MiB TUF_ROOT=$TEMP_DIR/sigstore \
    cosign verify-blob-attestation --new-bundle-format \
    --bundle "$TEMP_DIR/provenance.json" --type https://slsa.dev/provenance/v1 \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    --certificate-identity "https://github.com/backnotprop/plannotator/.github/workflows/release.yml@refs/tags/$PLANNOTATOR_VERSION" \
    "$TEMP_DIR/$asset"
install -m 755 "$TEMP_DIR/$asset" "$BIN_DIR/plannotator"
printf 'mattpocock/skills %s\nbacknotprop/plannotator %s\n' \
    "$(git -C "$TEMP_DIR/matt" rev-parse HEAD)" "$PLANNOTATOR_VERSION" > "$SOURCE_DIR/versions.txt"
"$BIN_DIR/plannotator" --version
