#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
[[ -d dist/Folio.app ]] || { print -u2 'Run zsh scripts/package.sh first'; exit 1; }
codesign --verify --deep --strict dist/Folio.app
STAGE=$(mktemp -d "$PWD/dist/.installer.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/volume"
ditto dist/Folio.app "$STAGE/volume/Folio.app"
ln -s /Applications "$STAGE/volume/Applications"
cp packaging/INSTALL.txt "$STAGE/volume/Read me first.txt"
hdiutil create -volname Folio -srcfolder "$STAGE/volume" -format UDZO -ov "$STAGE/Folio.dmg"
hdiutil verify "$STAGE/Folio.dmg"
mv -f "$STAGE/Folio.dmg" dist/Folio.dmg
shasum -a 256 dist/Folio.dmg > dist/Folio.dmg.sha256
print 'Built dist/Folio.dmg'
