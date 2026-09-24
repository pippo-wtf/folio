# Building Folio

Requires macOS 14+, Xcode and Node.js with npm.

```sh
npm ci
npm test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
zsh scripts/package.sh
zsh scripts/installer.sh
```

Public builds replace `dist/Folio.app` and `dist/Folio.dmg`. Staging builds
replace `dist/Folio Staging.app`. The disposable update-test channel writes
only under `/private/tmp`. These builds do not create another version-named app. Version numbers remain in the app metadata for support.
The current script builds for the host architecture; the initial download is Apple silicon.

Quit the installed app before replacing it. Use the disk image’s Install Folio app to install into `~/Applications`.
The installer resolves the receiving user’s home at runtime and checks Folio’s
Developer ID signature before replacing an existing copy. It refuses to replace
a running Folio. Pass `FOLIO_CODESIGN_IDENTITY` to `scripts/installer.sh` to sign
the installer helper; notarize the resulting DMG before distributing it.
Do not delete user preferences or support data when updating. Local preview
builds keep the updater inactive. The signed release workflow and isolated
older-to-newer test are described in [Update delivery](docs/UPDATES.md).

The default package script signs locally with an ad-hoc identity. Distribution
uses Developer ID, the hardened runtime, EdDSA-signed update feeds and Apple
notarization. `scripts/notarize.sh` submits only when called explicitly. Never
commit certificates, private keys, signing passwords or notarization credentials.

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
