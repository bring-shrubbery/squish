#!/bin/bash
# Prints the paths changed since the previous release tag that are worth an app
# release, one per line; prints nothing when only documentation or the CLI changed.
# A git query that fails (an unknown tag) exits non-zero; the workflow must stop,
# not treat it as nothing to release.
#
#   release-changes.sh v1.0.2   paths changed between v1.0.2 and HEAD
#   release-changes.sh ""       every tracked path (no release exists yet)
#
# Documentation is docs/, the website under web/, any *.md, LICENSE, NOTICE
# and .github/ except the workflows. The squish CLI (cli/, its cli-*.yml workflows and
# its release-cli-* scripts) ships on its own cli-v* tags. RELEASE_PATHS (one path per line) replaces
# the git query; the test uses it.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
previous=${1-}

changed_paths() {
    if [ -n "${RELEASE_PATHS+x}" ]; then
        printf '%s\n' "$RELEASE_PATHS"
    elif [ -n "$previous" ]; then
        git -C "$ROOT" diff --name-only "$previous" HEAD
    else
        git -C "$ROOT" ls-tree -r --full-tree --name-only HEAD
    fi
}

is_documentation() {
    case "$1" in
        docs/*|web/*|*.md|LICENSE|NOTICE) return 0 ;;
        cli/*|.github/workflows/cli-*.yml|scripts/release-cli-*) return 0 ;;
        .github/workflows/*) return 1 ;;
        .github/*) return 0 ;;
    esac
    return 1
}

changed_paths | while IFS= read -r path; do
    [ -n "$path" ] || continue
    is_documentation "$path" || echo "$path"
done
