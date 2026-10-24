#!/usr/bin/env bash
# Keep a skills directory's links to the image's skill collection current.
# Usage: link-skills.sh SKILLS_DIR on|off
set -euo pipefail
TARGET=${1:?Skills directory required}
STATE=${2:?on or off required}
TOOLING=${DEVCAR_TOOLING:-/opt/devcar/tooling}

declare -A wanted=()
case $STATE in
    on)
        while IFS= read -r skill; do
            [[ -z $skill ]] || wanted[${skill##*/}]=$TOOLING/$skill
        done < "$TOOLING/skills.list"
        mkdir -p -- "$TARGET" ;;
    off) [[ -d $TARGET ]] || exit 0 ;;
    *) echo 'Expected on or off.' >&2; exit 2 ;;
esac

# Links into the tooling directory are ours; anything else belongs to the user.
for link in "$TARGET"/*; do
    [[ -L $link ]] || continue
    destination=$(readlink -- "$link")
    if [[ $destination == "$TOOLING"/* && ${wanted[${link##*/}]:-} != "$destination" ]]; then
        rm -- "$link"
    fi
done
for name in "${!wanted[@]}"; do
    link=$TARGET/$name
    if [[ ! -L $link && ! -e $link ]]; then
        ln -s -- "${wanted[$name]}" "$link"
    elif [[ $(readlink -- "$link" || true) != "${wanted[$name]}" ]]; then
        echo "Keeping $link instead of the image's $name skill." >&2
    fi
done
