#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
[[ -d dist/Folio.app ]] || { print -u2 'Run zsh scripts/package.sh first'; exit 1; }
codesign --verify --deep --strict dist/Folio.app
STAGE=$(mktemp -d "$PWD/dist/.installer.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/volume"
# A portable installer resolves the receiving user's home at runtime. A DMG
# symlink cannot express ~/Applications without baking in the build user's path.
INSTALLER="$STAGE/volume/Install Folio.app"
mkdir -p "$INSTALLER/Contents/MacOS" "$INSTALLER/Contents/Resources"
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} xcrun swiftc -O -target arm64-apple-macos14.0 packaging/InstallFolio.swift Sources/ReaderCore/PersonalAppInstallation.swift -o "$INSTALLER/Contents/MacOS/InstallFolio" -framework AppKit -framework Security
ditto dist/Folio.app "$INSTALLER/Contents/Resources/Folio.app"
cp packaging/Folio.icns "$INSTALLER/Contents/Resources/Folio.icns"
cat > "$INSTALLER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>wtf.pippo.folio.installer</string>
<key>CFBundleName</key><string>Install Folio</string>
<key>CFBundleExecutable</key><string>InstallFolio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>Folio</string>
<key>CFBundleShortVersionString</key><string>0.13.0</string>
<key>CFBundleVersion</key><string>2026092404</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
IDENTITY=${FOLIO_CODESIGN_IDENTITY:--}
[[ "$IDENTITY" == 'Developer ID Application:'* ]] || { print -u2 'Set FOLIO_CODESIGN_IDENTITY to a Developer ID Application identity for the installer.'; exit 1; }
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$INSTALLER"
codesign --verify --deep --strict "$INSTALLER"
if [[ "${FOLIO_NOTARIZE_INSTALLER:-0}" == 1 ]]; then
  zsh scripts/notarize.sh "$INSTALLER"
fi
cp packaging/INSTALL.txt "$STAGE/volume/Read me first.txt"
hdiutil create -volname Folio -srcfolder "$STAGE/volume" -format UDZO -ov "$STAGE/Folio.dmg"
hdiutil verify "$STAGE/Folio.dmg"
mv -f "$STAGE/Folio.dmg" dist/Folio.dmg
shasum -a 256 dist/Folio.dmg > dist/Folio.dmg.sha256
print 'Built dist/Folio.dmg'
