#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
npm run bundle
swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)
mkdir -p dist
STAGE=$(mktemp -d "$PWD/dist/.package.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Folio.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Folio" "$APP/Contents/MacOS/Folio"
for bundle in "$BIN_DIR"/*.bundle(N); do cp -R "$bundle" "$APP/Contents/Resources/"; done
cp packaging/Folio.icns "$APP/Contents/Resources/Folio.icns"
cp packaging/Info.plist "$APP/Contents/Info.plist"
EXT="$APP/Contents/PlugIns/FolioPreview.appex"
mkdir -p "$EXT/Contents/MacOS" "$EXT/Contents/Resources"
xcrun swiftc -O -parse-as-library -application-extension -module-name FolioPreview -framework AppKit -framework WebKit -framework QuickLookUI -Xlinker -e -Xlinker _NSExtensionMain QuickLook/PreviewViewController.swift -o "$EXT/Contents/MacOS/FolioPreview"
cp QuickLook/Info.plist "$EXT/Contents/Info.plist"
cp Sources/MarkdownReader/Resources/reader.js Sources/MarkdownReader/Resources/reader.css Sources/MarkdownReader/Resources/math.css "$EXT/Contents/Resources/"
cp Sources/MarkdownReader/Resources/Fonts/*.ttf "$EXT/Contents/Resources/"
cp Sources/MarkdownReader/Resources/Fonts/*OFL.txt Sources/MarkdownReader/Resources/THIRD_PARTY.txt "$EXT/Contents/Resources/"
codesign --force --sign - --entitlements QuickLook/Preview.entitlements "$EXT"
codesign --force --sign - --entitlements packaging/Folio.entitlements "$APP"
codesign --verify --deep --strict "$APP"
# Only replace the last build after the new bundle has passed signature checks.
if [[ -e dist/Folio.app ]]; then mv dist/Folio.app "$STAGE/Previous.app"; fi
if ! mv "$APP" dist/Folio.app; then
  [[ ! -e "$STAGE/Previous.app" ]] || mv "$STAGE/Previous.app" dist/Folio.app
  exit 1
fi
print "Built dist/Folio.app (local development preview; not notarized)"
