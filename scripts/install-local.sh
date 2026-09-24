#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
[[ -d dist/Folio.app ]] || { print -u2 'Build Folio first'; exit 1; }
DEST="$HOME/Applications/Folio.app"
if pgrep -f "$DEST/Contents/MacOS/Folio" >/dev/null; then
  print -u2 'Quit Folio before updating it.'; exit 1
fi
mkdir -p "$HOME/Applications"
STAGE=$(mktemp -d "$HOME/Applications/.folio-update.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto dist/Folio.app "$STAGE/Folio.app"
codesign --verify --deep --strict "$STAGE/Folio.app"
[[ ! -e "$DEST" ]] || mv "$DEST" "$STAGE/Previous.app"
if ! mv "$STAGE/Folio.app" "$DEST"; then
  [[ ! -e "$STAGE/Previous.app" ]] || mv "$STAGE/Previous.app" "$DEST"
  exit 1
fi
print "Updated $DEST"
