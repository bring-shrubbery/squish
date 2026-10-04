#!/bin/bash
# Exercises release-notes.sh: the area prefix goes, documentation commits go, the HTML is
# escaped and well formed. Run: scripts/release-notes-test.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/release-notes.sh"
failures=0
nl=$'\n'

# check <label> <format> <subjects, | separated> <expected output>
check() {
    local label=$1 format=$2 subjects=$3 want=$4 got
    got=$(RELEASE_SUBJECTS="${subjects//|/$nl}" "$SCRIPT" v0.0.0 "$format")
    if [ "$got" = "$want" ]; then
        echo "ok   $label"
    else
        echo "FAIL $label"; printf '  got:\n%s\n  want:\n%s\n' "$got" "$want"
        failures=$((failures + 1))
    fi
}

check "markdown list, oldest first, prefixes dropped" --markdown \
    "core: a paste command|app: cut, copy and paste the selection|ui: a right-click opens the card" \
    "- A paste command${nl}- Cut, copy and paste the selection${nl}- A right-click opens the card"

check "documentation, website and ci commits are left out" --markdown \
    "docs: the design|web: node 24|ci: run on node 24|audio: an audition is heard|chore: bump the toolchain|build: the release signs the zip" \
    "- An audition is heard${nl}- The release signs the zip"

check "conventional types and scopes" --markdown \
    "feat(app): render questions|fix(core)!: alert on growth|docs(app): notes|feat(web): hero|chore: bump|test(core): more" \
    "- Render questions${nl}- Alert on growth"

check "a subject without an area is kept as it is" --markdown \
    "initial import" \
    "- Initial import"

check "nothing left is a maintenance release" --markdown \
    "docs: only" \
    "- Maintenance release."

check "html list, escaped" --html \
    "core: a <T> helper & more|app: paste" \
    "<ul>${nl}  <li>A &lt;T&gt; helper &amp; more</li>${nl}  <li>Paste</li>${nl}</ul>"

out=$(RELEASE_SUBJECTS="core: a <T> helper & more" "$SCRIPT" v0.0.0 --html)
if printf '%s' "$out" | xmllint --noout - 2>/dev/null; then echo "ok   html is well-formed xml"; else echo "FAIL html does not parse"; failures=$((failures + 1)); fi

if "$SCRIPT" v0.0.0 >/dev/null 2>&1; then
    echo "FAIL a missing format should fail"; failures=$((failures + 1))
else
    echo "ok   missing format fails"
fi

# With no previous tag the real repo's history is listed; it is non-empty.
if [ -n "$("$SCRIPT" "" --markdown)" ]; then
    echo "ok   no previous tag -> whole history"
else
    echo "FAIL no previous tag should list the history"; failures=$((failures + 1))
fi

[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
