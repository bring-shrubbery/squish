#!/bin/bash
# Exercises the docs-only filter in release-changes.sh. Run: scripts/release-changes-test.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/release-changes.sh"
failures=0
nl=$'\n'

# check <label> <paths, space separated> <expected output, space separated>
check() {
    local label=$1 paths=$2 want=$3 got
    got=$(RELEASE_PATHS="${paths// /$nl}" "$SCRIPT" v0.0.0 | tr '\n' ' ' | sed 's/ $//')
    if [ "$got" = "$want" ]; then
        echo "ok   $label -> [${got}]"
    else
        echo "FAIL $label -> got [${got}], want [${want}]"
        failures=$((failures + 1))
    fi
}

check "docs only"        "docs/design/x.md README.md LICENSE NOTICE .github/MAINTAINERS .github/ISSUE_TEMPLATE/bug.yml" ""
check "app source"       "Sources/SquishApp/AppState.swift README.md" "Sources/SquishApp/AppState.swift"
check "workflow"         ".github/workflows/ci.yml .github/CODEOWNERS" ".github/workflows/ci.yml"
check "submodule bump"   "app/ThirdParty/demucs.cpp .gitmodules" "app/ThirdParty/demucs.cpp .gitmodules"
check "script"           "scripts/build-app.sh docs/icon.png" "scripts/build-app.sh"
check "md under app"     "Sources/SquishCore/README.md Package.swift" "Package.swift"
check "nothing"          "" ""
check "website"          "web/src/pages/index.astro web/package.json" ""
check "website and app"  "web/src/pages/index.astro scripts/build-app.sh" "scripts/build-app.sh"

# With no previous tag every tracked path counts; the real repo has code, so output is non-empty.
if [ -n "$("$SCRIPT" "")" ]; then
    echo "ok   no previous tag -> whole tree"
else
    echo "FAIL no previous tag should list the tree"; failures=$((failures + 1))
fi

# An unknown tag is an error, never "nothing to release".
if "$SCRIPT" no-such-tag-0000 >/dev/null 2>&1; then
    echo "FAIL an unknown tag should exit non-zero"; failures=$((failures + 1))
else
    echo "ok   unknown tag exits non-zero"
fi

[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
