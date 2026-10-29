#!/bin/bash
# Exercises release-cli-formula.sh: every target gets its URL and digest, and a missing or
# malformed digest fails. Run: scripts/release-cli-formula-test.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/release-cli-formula.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
failures=0

ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }

targets="aarch64-apple-darwin x86_64-apple-darwin aarch64-unknown-linux-musl x86_64-unknown-linux-musl"
i=0
for target in $targets; do
    i=$((i + 1))
    printf '%064d  squish-1.2.3-%s.tar.gz\n' "$i" "$target" > "$WORK/squish-1.2.3-$target.tar.gz.sha256"
done

formula=$("$SCRIPT" --version 1.2.3 --repo owner/name --sha-dir "$WORK")
for target in $targets; do
    if grep -q "url \"https://github.com/owner/name/releases/download/cli-v1.2.3/squish-1.2.3-$target.tar.gz\"" <<< "$formula"; then
        ok "url for $target"
    else
        fail "url for $target"
    fi
done
if [ "$(grep -c 'sha256 "0\{63\}[1-4]"' <<< "$formula")" -eq 4 ]; then ok "four digests"; else fail "four digests"; fi
if grep -q 'version "1.2.3"' <<< "$formula"; then ok "version"; else fail "version"; fi

if command -v ruby >/dev/null; then
    if ruby -c <<< "$formula" >/dev/null; then ok "ruby syntax"; else fail "ruby syntax"; fi
fi

if "$SCRIPT" --version 1.2 --repo owner/name --sha-dir "$WORK" >/dev/null 2>&1; then
    fail "a malformed version should fail"
else
    ok "malformed version fails"
fi

rm "$WORK/squish-1.2.3-x86_64-unknown-linux-musl.tar.gz.sha256"
if "$SCRIPT" --version 1.2.3 --repo owner/name --sha-dir "$WORK" >/dev/null 2>&1; then
    fail "a missing digest should fail"
else
    ok "missing digest fails"
fi

echo "nope  squish-1.2.3-x86_64-unknown-linux-musl.tar.gz" > "$WORK/squish-1.2.3-x86_64-unknown-linux-musl.tar.gz.sha256"
if "$SCRIPT" --version 1.2.3 --repo owner/name --sha-dir "$WORK" >/dev/null 2>&1; then
    fail "a malformed digest should fail"
else
    ok "malformed digest fails"
fi

[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
