#!/bin/zsh
# Explicit release operation. Never invoked by package.sh or installer.sh.
set -euo pipefail
cd "${0:A:h}/.."
ARTIFACT="${1:-}"
[[ -n "$ARTIFACT" && ( "$ARTIFACT" == *.app || "$ARTIFACT" == *.dmg ) ]] || {
  print -u2 'Usage: zsh scripts/notarize.sh PATH_TO_SIGNED_APP_OR_DMG'; exit 2
}
[[ -e "$ARTIFACT" ]] || { print -u2 "No such artifact: $ARTIFACT"; exit 2; }
PROFILE="${FOLIO_NOTARY_PROFILE:-FolioNotary}"
STAGE=$(mktemp -d /private/tmp/folio-notary.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
if [[ "$ARTIFACT" == *.app ]]; then
  codesign --verify --deep --strict "$ARTIFACT"
  ARCHIVE="$STAGE/${ARTIFACT:t}.zip"
  ditto -c -k --sequesterRsrc --keepParent "$ARTIFACT" "$ARCHIVE"
else
  hdiutil verify "$ARTIFACT"
  ARCHIVE="$ARTIFACT"
fi
RESULT=$(xcrun notarytool submit "$ARCHIVE" --keychain-profile "$PROFILE" --wait --output-format json)
print -r -- "$RESULT" > "$STAGE/result.json"
python3 - "$STAGE/result.json" <<'PYSTATUS'
import json, sys
with open(sys.argv[1]) as source:
    result = json.load(source)
print('Notary submission:', result.get('id', '(unknown)'), result.get('status', '(unknown)'))
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization did not return Accepted; artifact was not stapled')
PYSTATUS
xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
print "Accepted and stapled: $ARTIFACT"
