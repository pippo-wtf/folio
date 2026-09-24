#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
CHANNEL="${1:-public}"
case "$CHANNEL" in
  public) APP_NAME=Folio; FLAGS=();;
  staging) APP_NAME="Folio Staging"; FLAGS=(-Xswiftc -DFOLIO_STAGING);;
  *) print -u2 'Use public or staging'; exit 1;;
esac
BUILD_DIR=".build/$CHANNEL"
npm run bundle
swift build -c release --scratch-path "$BUILD_DIR" "${FLAGS[@]}"
BIN_DIR=$(swift build -c release --scratch-path "$BUILD_DIR" "${FLAGS[@]}" --show-bin-path)
mkdir -p dist
STAGE=$(mktemp -d "$PWD/dist/.package.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Folio" "$APP/Contents/MacOS/Folio"
for bundle in "$BIN_DIR"/*.bundle(N); do cp -R "$bundle" "$APP/Contents/Resources/"; done
cp packaging/Folio.icns "$APP/Contents/Resources/Folio.icns"
cp packaging/Info.plist "$APP/Contents/Info.plist"
if [[ "$CHANNEL" == staging ]]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier wtf.pippo.folio.staging' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName Folio Staging' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Folio Staging' "$APP/Contents/Info.plist"
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
codesign --force --sign - --entitlements QuickLook/Preview.entitlements "$EXT"
fi
codesign --force --sign - --entitlements packaging/Folio.entitlements "$APP"
codesign --verify --deep --strict "$APP"
# Only replace the last build after the new bundle has passed signature checks.
if [[ -e "dist/$APP_NAME.app" ]]; then mv "dist/$APP_NAME.app" "$STAGE/Previous.app"; fi
if ! mv "$APP" "dist/$APP_NAME.app"; then
  [[ ! -e "$STAGE/Previous.app" ]] || mv "$STAGE/Previous.app" "dist/$APP_NAME.app"
  exit 1
fi
print "Built dist/$APP_NAME.app (local development preview; not notarized)"
