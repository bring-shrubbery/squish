#!/bin/bash
# Prints the release notes for the commits since the previous release tag: one line per
# commit subject, oldest first, with its `type(scope):` prefix dropped and the first letter
# raised. Commits that change nothing in the app are left out: the types docs, web, ci, test
# and chore, and the scopes docs, web and ci (`feat(web): …`). A release with nothing left
# says "Maintenance release."
#
#   release-notes.sh v1.0.2 --html       an <ul> for the appcast's <description>
#   release-notes.sh v1.0.2 --markdown   a list for the GitHub release body
#   release-notes.sh "" --html           every commit (no release exists yet)
#
# RELEASE_SUBJECTS (one subject per line, oldest first) replaces the git query; the test
# uses it.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
previous=${1-}
format=${2-}

case "$format" in
    --html|--markdown) ;;
    *) echo "usage: release-notes.sh <previous-tag or \"\"> --html|--markdown" >&2; exit 1 ;;
esac

subjects() {
    if [ -n "${RELEASE_SUBJECTS+x}" ]; then
        printf '%s\n' "$RELEASE_SUBJECTS"
    elif [ -n "$previous" ]; then
        git -C "$ROOT" log --no-merges --reverse --format=%s "$previous..HEAD"
    else
        git -C "$ROOT" log --no-merges --reverse --format=%s HEAD
    fi
}

# The subject without its prefix, capitalised; nothing for a commit the app never sees.
entry() {
    local subject=$1 area="" rest type scope=""
    case "$subject" in
        *:\ *) area=${subject%%:*}; rest=${subject#*: } ;;
        *) rest=$subject ;;
    esac
    area=${area%!}
    type=${area%%(*}
    case "$area" in
        *\(*\)) scope=${area#*(}; scope=${scope%)} ;;
    esac
    case "$type" in
        docs|web|ci|test|chore) return 0 ;;
    esac
    case "$scope" in
        docs|web|ci) return 0 ;;
    esac
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || return 0
    printf '%s\n' "$(printf '%s' "${rest:0:1}" | tr '[:lower:]' '[:upper:]')${rest:1}"
}

escape_html() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

entries=$(subjects | while IFS= read -r subject; do
    [ -n "$subject" ] || continue
    entry "$subject"
done)

[ -n "$entries" ] || entries="Maintenance release."

if [ "$format" = "--html" ]; then
    echo "<ul>"
    printf '%s\n' "$entries" | escape_html | sed 's/.*/  <li>&<\/li>/'
    echo "</ul>"
else
    printf '%s\n' "$entries" | sed 's/.*/- &/'
fi
