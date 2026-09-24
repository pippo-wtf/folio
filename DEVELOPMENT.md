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

## Staging

The public build hides Layout and Presets. Save is an icon in both editions.

```sh
zsh scripts/package.sh public
zsh scripts/installer.sh
zsh scripts/install-local.sh public
zsh scripts/package.sh staging
zsh scripts/install-local.sh staging
```

This maintains exactly two named apps: `Folio.app` and `Folio Staging.app`.
Staging uses a separate bundle identifier, preferences, recovery drafts and highlights.
Both begin with the approved appearance; subsequent changes are independent.
Opening and saving an original document still changes that same file in either app.
Staging does not register Markdown file associations or install a Quick Look extension.
It is not included in the public installer.
