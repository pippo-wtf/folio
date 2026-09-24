#!/bin/zsh
# Build two disposable, Developer ID signed Folio Update Test bundles and a
# locally hosted, EdDSA-signed Sparkle appcast. Does not launch or install them.
set -euo pipefail
cd "${0:A:h}/.."
[[ -n "${FOLIO_CODESIGN_IDENTITY:-}" ]] || { print -u2 'Set FOLIO_CODESIGN_IDENTITY to a Developer ID Application identity'; exit 1; }
PORT="${FOLIO_TEST_PORT:-8765}"
[[ "$PORT" =~ '^[0-9]+$' ]] && (( PORT >= 1024 && PORT <= 65535 )) || { print -u2 'FOLIO_TEST_PORT must be 1024–65535'; exit 1; }
ROOT=$(mktemp -d /private/tmp/folio-update-test.XXXXXX)
BUILD_OUTPUT="$ROOT/build"
INSTALLED="$ROOT/installed/Folio Update Test.app"
FEED_DIR="$ROOT/feed"
mkdir -p "$ROOT/installed" "$FEED_DIR"
FEED_URL="http://127.0.0.1:$PORT/appcast.xml"
PUBLIC_KEY=$(python3 - <<'PYPUBLICKEY'
import json
with open('packaging/update-public-keys.json') as source:
    print(json.load(source)['staging'])
PYPUBLICKEY
)

FOLIO_DISTRIBUTION=1 FOLIO_TEST_ED_KEY="$PUBLIC_KEY" \
FOLIO_TEST_FEED_URL="$FEED_URL" FOLIO_TEST_OUTPUT_DIR="$BUILD_OUTPUT" \
FOLIO_BUILD_VERSION=990001 FOLIO_SHORT_VERSION=99.0.1 \
zsh scripts/package.sh test
ditto "$BUILD_OUTPUT/Folio Update Test.app" "$INSTALLED"

FOLIO_DISTRIBUTION=1 FOLIO_TEST_ED_KEY="$PUBLIC_KEY" \
FOLIO_TEST_FEED_URL="$FEED_URL" FOLIO_TEST_OUTPUT_DIR="$BUILD_OUTPUT" \
FOLIO_BUILD_VERSION=990002 FOLIO_SHORT_VERSION=99.0.2 \
zsh scripts/package.sh test
ARCHIVE="$FEED_DIR/Folio-Update-Test-99.0.2.zip"
ditto -c -k --sequesterRsrc --keepParent "$BUILD_OUTPUT/Folio Update Test.app" "$ARCHIVE"
cat > "$FEED_DIR/Folio-Update-Test-99.0.2.md" <<'NOTES'
# Folio Update Test 99.0.2

This is a disposable local test of signed, user-initiated in-app updates.
No public or staging Folio app or data is involved.
NOTES
TOOL=".build/test/artifacts/sparkle/Sparkle/bin/generate_appcast"
[[ -x "$TOOL" ]] || { print -u2 "Missing Sparkle tool: $TOOL"; exit 1; }
"$TOOL" --account wtf.pippo.folio.staging --download-url-prefix "http://127.0.0.1:$PORT/" --maximum-deltas 0 -o "$FEED_DIR/appcast.xml" "$FEED_DIR"
python3 - "$INSTALLED" "$BUILD_OUTPUT/Folio Update Test.app" "$FEED_DIR/appcast.xml" "$FEED_URL" <<'PYVERIFY'
import plistlib, sys
from pathlib import Path
old, new, feed = map(Path, sys.argv[1:4])
expected_url = sys.argv[4]
for app, expected_build in [(old, '990001'), (new, '990002')]:
    with (app / 'Contents/Info.plist').open('rb') as source:
        info = plistlib.load(source)
    assert info['CFBundleIdentifier'] == 'wtf.pippo.folio.update-test'
    assert info['CFBundleVersion'] == expected_build
    assert info['SUFeedURL'] == expected_url
    assert info['SUAllowsAutomaticUpdates'] is False
    assert info['SUAutomaticallyUpdate'] is False
    assert info['SURequireSignedFeed'] is True
text = feed.read_text()
assert 'edSignature' in text and 'appcast' in text and '990002' in text
PYVERIFY
codesign --verify --deep --strict "$INSTALLED"
codesign --verify --deep --strict "$BUILD_OUTPUT/Folio Update Test.app"
print "Prepared disposable update test under $ROOT"
print "Start feed: python3 -m http.server $PORT --bind 127.0.0.1 --directory '$FEED_DIR'"
print "Launch old app: open '$INSTALLED'"
print "Expected after clicking Update: build 990002 in '$INSTALLED'"
