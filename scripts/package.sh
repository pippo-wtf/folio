#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
CHANNEL="${1:-public}"
case "$CHANNEL" in
  public) APP_NAME=Folio; FLAGS=(); BUNDLE_ID=wtf.pippo.markdown-reader
          FEED_URL="${FOLIO_PUBLIC_FEED_URL:-https://raw.githubusercontent.com/pippo-wtf/folio/main/updates/public.xml}"
          PUBLIC_KEY="${FOLIO_PUBLIC_ED_KEY:-}";;
  staging) APP_NAME="Folio Staging"; FLAGS=(-Xswiftc -DFOLIO_STAGING); BUNDLE_ID=wtf.pippo.folio.staging
           FEED_URL="${FOLIO_STAGING_FEED_URL:-https://raw.githubusercontent.com/pippo-wtf/folio/main/updates/staging.xml}"
           PUBLIC_KEY="${FOLIO_STAGING_ED_KEY:-}";;
  test) APP_NAME="Folio Update Test"; FLAGS=(-Xswiftc -DFOLIO_UPDATE_TEST); BUNDLE_ID=wtf.pippo.folio.update-test
        FEED_URL="${FOLIO_TEST_FEED_URL:-http://127.0.0.1:8765/appcast.xml}"
        PUBLIC_KEY="${FOLIO_TEST_ED_KEY:-}";;
  *) print -u2 'Use public, staging, or test'; exit 1;;
esac
OUTPUT_DIR=dist
if [[ "$CHANNEL" == test ]]; then
  [[ -n "${FOLIO_TEST_OUTPUT_DIR:-}" ]] || { print -u2 'Test channel requires FOLIO_TEST_OUTPUT_DIR under /private/tmp'; exit 1; }
  [[ "$FOLIO_TEST_OUTPUT_DIR" == /private/tmp/* || "$FOLIO_TEST_OUTPUT_DIR" == /tmp/* ]] || { print -u2 'Test output must be under /private/tmp'; exit 1; }
  mkdir -p "$FOLIO_TEST_OUTPUT_DIR"
  OUTPUT_DIR="${FOLIO_TEST_OUTPUT_DIR:A}"
  [[ "$OUTPUT_DIR" == /private/tmp/* ]] || { print -u2 'Test output must resolve under /private/tmp'; exit 1; }
fi
DISTRIBUTION="${FOLIO_DISTRIBUTION:-0}"
SIGN_IDENTITY="${FOLIO_CODESIGN_IDENTITY:--}"
# Public keys are distributable metadata. Keep private EdDSA keys in Keychain.
if [[ "$DISTRIBUTION" == 1 && "$CHANNEL" != test ]]; then
  TRACKED_KEY=$(python3 - "$CHANNEL" <<'PYPUBLICKEY'
import json, sys
with open('packaging/update-public-keys.json') as source:
    print(json.load(source)[sys.argv[1]])
PYPUBLICKEY
  )
  if [[ -n "$PUBLIC_KEY" && "$PUBLIC_KEY" != "$TRACKED_KEY" ]]; then
    print -u2 'Distribution EdDSA key differs from the reviewed public key file'; exit 1
  fi
  PUBLIC_KEY="$TRACKED_KEY"
fi
if [[ "$DISTRIBUTION" != 0 && "$DISTRIBUTION" != 1 ]]; then
  print -u2 'FOLIO_DISTRIBUTION must be 0 or 1'; exit 1
fi
if [[ "$DISTRIBUTION" == 1 && ( -z "$PUBLIC_KEY" || "$SIGN_IDENTITY" != 'Developer ID Application:'* || -z "${FOLIO_BUILD_VERSION:-}" ) ]]; then
  print -u2 'Distribution requires a channel EdDSA public key, Developer ID Application signing identity, and FOLIO_BUILD_VERSION'; exit 1
fi
if [[ -n "$PUBLIC_KEY" ]]; then
  FOLIO_FEED_URL="$FEED_URL" FOLIO_PUBLIC_KEY="$PUBLIC_KEY" FOLIO_CHANNEL="$CHANNEL" python3 - <<'PYVALIDATE'
import base64, os, urllib.parse
url = urllib.parse.urlparse(os.environ['FOLIO_FEED_URL'])
allow_test_http = os.environ['FOLIO_CHANNEL'] == 'test' and url.scheme == 'http' and url.hostname == '127.0.0.1'
if not (url.scheme == 'https' or allow_test_http) or not url.hostname or url.username or url.password:
    raise SystemExit('Sparkle feed must be HTTPS (test channel may use loopback HTTP)')
try:
    key = base64.b64decode(os.environ['FOLIO_PUBLIC_KEY'], validate=True)
except ValueError:
    raise SystemExit('Sparkle EdDSA public key is not valid base64')
if len(key) != 32:
    raise SystemExit('Sparkle EdDSA public key must decode to 32 bytes')
PYVALIDATE
fi
if [[ -n "${FOLIO_BUILD_VERSION:-}" && ! "${FOLIO_BUILD_VERSION}" =~ '^[0-9]+(\.[0-9]+)*$' ]]; then
  print -u2 'FOLIO_BUILD_VERSION must be a numeric version that increases each release'; exit 1
fi
if [[ -n "${FOLIO_SHORT_VERSION:-}" && ! "${FOLIO_SHORT_VERSION}" =~ '^[0-9]+(\.[0-9]+)*$' ]]; then
  print -u2 'FOLIO_SHORT_VERSION must be a numeric dotted version'; exit 1
fi
BUILD_DIR=".build/$CHANNEL"
npm run bundle
swift build -c release --scratch-path "$BUILD_DIR" "${FLAGS[@]}"
BIN_DIR=$(swift build -c release --scratch-path "$BUILD_DIR" "${FLAGS[@]}" --show-bin-path)
SPARKLE_FRAMEWORK="$BUILD_DIR/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$SPARKLE_FRAMEWORK" ]] || { print -u2 "Missing Sparkle framework: $SPARKLE_FRAMEWORK"; exit 1; }
mkdir -p "$OUTPUT_DIR"
STAGE=$(mktemp -d "$OUTPUT_DIR/.package.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Folio" "$APP/Contents/MacOS/Folio"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
for bundle in "$BIN_DIR"/*.bundle(N); do cp -R "$bundle" "$APP/Contents/Resources/"; done
cp packaging/Folio.icns "$APP/Contents/Resources/Folio.icns"
cp packaging/Info.plist "$APP/Contents/Info.plist"
if [[ "$CHANNEL" == staging || "$CHANNEL" == test ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Delete :CFBundleDocumentTypes' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Delete :UTImportedTypeDeclarations' "$APP/Contents/Info.plist"
else
EXT="$APP/Contents/PlugIns/FolioPreview.appex"
mkdir -p "$EXT/Contents/MacOS" "$EXT/Contents/Resources"
xcrun swiftc -O -parse-as-library -application-extension -module-name FolioPreview -framework AppKit -framework WebKit -framework QuickLookUI -Xlinker -e -Xlinker _NSExtensionMain QuickLook/PreviewViewController.swift -o "$EXT/Contents/MacOS/FolioPreview"
cp QuickLook/Info.plist "$EXT/Contents/Info.plist"
cp Sources/MarkdownReader/Resources/reader.js Sources/MarkdownReader/Resources/reader.css Sources/MarkdownReader/Resources/math.css "$EXT/Contents/Resources/"
cp Sources/MarkdownReader/Resources/Fonts/*.ttf "$EXT/Contents/Resources/"
cp Sources/MarkdownReader/Resources/Fonts/*OFL.txt Sources/MarkdownReader/Resources/THIRD_PARTY.txt "$EXT/Contents/Resources/"
# The extension is signed after the nested Sparkle helpers below.
fi
# PlistBuddy does not expand Xcode macros in entitlements; generate exact
# sandbox mach service names for each app ID. Preview builds omit feed keys.
FOLIO_APP_PATH="$APP" FOLIO_BUNDLE_ID="$BUNDLE_ID" FOLIO_FEED_URL="$FEED_URL" FOLIO_PUBLIC_KEY="$PUBLIC_KEY" FOLIO_BUILD_VERSION="${FOLIO_BUILD_VERSION:-}" FOLIO_SHORT_VERSION="${FOLIO_SHORT_VERSION:-}" python3 - <<'PYPLIST'
import os, plistlib
from pathlib import Path
app = Path(os.environ['FOLIO_APP_PATH'])
plist_path = app / 'Contents/Info.plist'
with plist_path.open('rb') as source:
    info = plistlib.load(source)
if os.environ['FOLIO_PUBLIC_KEY']:
    info.update({
        'SUFeedURL': os.environ['FOLIO_FEED_URL'],
        'SUPublicEDKey': os.environ['FOLIO_PUBLIC_KEY'],
        'SUEnableAutomaticChecks': True,
        'SUAllowsAutomaticUpdates': False,
        'SUAutomaticallyUpdate': False,
        'SUShowReleaseNotes': True,
        'SUEnableInstallerLauncherService': True,
        'SUVerifyUpdateBeforeExtraction': True,
        'SURequireSignedFeed': True,
        'SUSignedFeedFailureExpirationInterval': 0,
    })
if os.environ['FOLIO_BUILD_VERSION']:
    info['CFBundleVersion'] = os.environ['FOLIO_BUILD_VERSION']
if os.environ['FOLIO_SHORT_VERSION']:
    info['CFBundleShortVersionString'] = os.environ['FOLIO_SHORT_VERSION']
if os.environ['FOLIO_BUNDLE_ID'] == 'wtf.pippo.folio.update-test':
    # The disposable fixture alone may fetch a signed feed from loopback HTTP.
    info['NSAppTransportSecurity'] = {'NSAllowsLocalNetworking': True}
with plist_path.open('wb') as destination:
    plistlib.dump(info, destination)
with open('packaging/Folio.entitlements', 'rb') as source:
    entitlements = plistlib.load(source)
bundle = os.environ['FOLIO_BUNDLE_ID']
entitlements['com.apple.security.temporary-exception.mach-lookup.global-name'] = [bundle + '-spks', bundle + '-spki']
with (app.parent / 'Folio-signing.entitlements').open('wb') as destination:
    plistlib.dump(entitlements, destination)
PYPLIST
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$DISTRIBUTION" == 1 ]]; then SIGN_ARGS+=(--options runtime --timestamp); fi
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
# Explicit order preserves each helper's own entitlements; never sign --deep.
codesign "${SIGN_ARGS[@]}" "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
codesign "${SIGN_ARGS[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
codesign "${SIGN_ARGS[@]}" "$FRAMEWORK/Versions/B/Updater.app"
codesign "${SIGN_ARGS[@]}" "$FRAMEWORK"
if [[ "$CHANNEL" == public ]]; then
  codesign "${SIGN_ARGS[@]}" --entitlements QuickLook/Preview.entitlements "$EXT"
fi
codesign "${SIGN_ARGS[@]}" --entitlements "$STAGE/Folio-signing.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
# Only replace the last build after the new bundle has passed signature checks.
if [[ -e "$OUTPUT_DIR/$APP_NAME.app" ]]; then mv "$OUTPUT_DIR/$APP_NAME.app" "$STAGE/Previous.app"; fi
if ! mv "$APP" "$OUTPUT_DIR/$APP_NAME.app"; then
  [[ ! -e "$STAGE/Previous.app" ]] || mv "$STAGE/Previous.app" "$OUTPUT_DIR/$APP_NAME.app"
  exit 1
fi
if [[ "$DISTRIBUTION" == 1 ]]; then
  print "Built $OUTPUT_DIR/$APP_NAME.app (Developer ID signed; notarization still required)"
else
  print "Built $OUTPUT_DIR/$APP_NAME.app (local development preview; not notarized)"
fi
