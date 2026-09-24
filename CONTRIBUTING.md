# Building Folio

Requires macOS 14+, Xcode and Node.js with npm.

```sh
npm ci
npm test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
zsh scripts/package.sh
zsh scripts/installer.sh
```

Builds always replace `dist/Folio.app` and `dist/Folio.dmg`. They do not create
another version-named app. Version numbers remain in the app metadata for support.
The current script builds for the host architecture; the initial download is Apple silicon.

Quit the installed app before replacing it. Copy `dist/Folio.app` into Applications.
Do not delete user preferences or support data when updating. Automatic updates are not implemented.

The package script signs locally with an ad-hoc identity. Public stable distribution
still requires a Developer ID certificate, hardened-runtime signing and Apple
notarization. Never commit certificates, signing passwords or notarization credentials.

The Markdown renderer is in `web/`, the Mac app in `Sources/`, and the preview
extension in `QuickLook/`. The bundle step generates offline renderer resources
and third-party notices. Font licenses are included beside the font files.

Personal research notes, local app builds and screenshots of user documents are
excluded from the public source. Release screenshots use a purpose-written sample.
