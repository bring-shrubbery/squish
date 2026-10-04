#!/bin/bash
# Exercises release-version.sh. Run: scripts/release-version-test.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/release-version.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
failures=0
nl=$'\n'

plist() {
    printf '<dict>\n    <key>CFBundleShortVersionString</key>\n    <string>%s</string>\n</dict>\n' "$1" > "$TMP/Info.plist"
}

# check <Info.plist version> <tags, space separated> <expected version> <expected previous>
check() {
    local floor=$1 tags=$2 want=$3 want_prev=$4
    plist "$floor"
    local got got_prev
    got=$(RELEASE_INFO_PLIST="$TMP/Info.plist" RELEASE_TAGS="${tags// /$nl}" "$SCRIPT")
    got_prev=$(RELEASE_INFO_PLIST="$TMP/Info.plist" RELEASE_TAGS="${tags// /$nl}" "$SCRIPT" --previous)
    if [ "$got" = "$want" ] && [ "$got_prev" = "$want_prev" ]; then
        echo "ok   plist=$floor tags=[$tags] -> $got (previous ${got_prev:-none})"
    else
        echo "FAIL plist=$floor tags=[$tags] -> got $got / ${got_prev:-none}, want $want / ${want_prev:-none}"
        failures=$((failures + 1))
    fi
}

check 1.0.0 ""                              1.0.0  ""
check 1.0.0 "v1.0.0-checkpoint"             1.0.0  ""
check 1.0.0 "v1.0.0"                        1.0.1  v1.0.0
check 1.0.0 "v1.0.0 v1.0.9"                 1.0.10 v1.0.9
check 1.0.0 "v1.0.9 v1.0.10"                1.0.11 v1.0.10
check 1.1.0 "v1.0.9"                        1.1.0  v1.0.9
check 1.0.0 "v1.1.2 v1.0.9"                 1.1.3  v1.1.2
check 1.0.0 "v1.0 v1.0.0-rc1 1.2.3 v2"      1.0.0  ""
check 2.0.0 "v1.9.9"                        2.0.0  v1.9.9
check 1.0.0 "v1.0.08"                       1.0.9  v1.0.08

# An Info.plist without a strict x.y.z version is an error.
plist 1.0
if RELEASE_INFO_PLIST="$TMP/Info.plist" RELEASE_TAGS="" "$SCRIPT" 2>/dev/null; then
    echo "FAIL a malformed version should fail"; failures=$((failures + 1))
else
    echo "ok   malformed version fails"
fi

# Against the real repo: whatever it prints must be x.y.z.
real=$("$SCRIPT")
if [[ "$real" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ok   real repo -> $real"
else
    echo "FAIL real repo -> '$real'"; failures=$((failures + 1))
fi

[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
