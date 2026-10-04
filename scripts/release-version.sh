#!/bin/bash
# Prints the version the next release gets: the higher of CFBundleShortVersionString in
# Support/Info.plist (the floor a maintainer raises for a minor or major release)
# and the highest v<major>.<minor>.<patch> tag with its patch + 1. With no such
# tag the Info.plist version is it. Pre-release tags (v1.0.0-checkpoint) are ignored.
#
#   release-version.sh             1.0.3
#   release-version.sh --previous  v1.0.2   (the highest release tag; empty when none)
#
# RELEASE_TAGS (one tag per line) replaces `git tag`, RELEASE_INFO_PLIST replaces the
# Info.plist; release-version-test.sh uses both.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
INFO_PLIST=${RELEASE_INFO_PLIST:-"$ROOT/Support/Info.plist"}

tags() {
    if [ -n "${RELEASE_TAGS+x}" ]; then printf '%s\n' "$RELEASE_TAGS"; else git -C "$ROOT" tag; fi
}

# Sorts x.y.z lines numerically, lowest first.
sort_versions() {
    sort -t. -k1,1n -k2,2n -k3,3n
}

# The highest strict release tag, without its v; empty when there is none.
highest_release() {
    tags | sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' | sort_versions | tail -1
}

# CFBundleShortVersionString from the Info.plist. sed, not PlistBuddy: the version job
# runs on Linux.
plist_version() {
    local version
    version=$(sed -n '/<key>CFBundleShortVersionString<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$INFO_PLIST")
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "error: CFBundleShortVersionString in $INFO_PLIST must be major.minor.patch, found: ${version:-none}" >&2
        exit 1
    fi
    echo "$version"
}

previous=$(highest_release)

if [ "${1:-}" = "--previous" ]; then
    [ -n "$previous" ] && echo "v$previous"
    exit 0
fi

floor=$(plist_version)
if [ -z "$previous" ]; then
    echo "$floor"
    exit 0
fi

IFS=. read -r major minor patch <<< "$previous"
next="$major.$minor.$((10#$patch + 1))"
printf '%s\n%s\n' "$floor" "$next" | sort_versions | tail -1
