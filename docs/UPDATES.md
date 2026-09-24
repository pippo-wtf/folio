# Folio update delivery

Folio 0.13.0 uses Sparkle 2.10.0. Public and staging apps have separate bundle
IDs, settings, storage, signed feeds, and EdDSA public keys. The app checks for
updates automatically and shows availability and release notes. Download,
verification, installation, and relaunch begin only after the user clicks
**Update**. **Check for Updates…** is in the app menu. Folio does not offer a
browser download as an update fallback.

## Security policy

`scripts/package.sh` sets `SUAllowsAutomaticUpdates = false` and
`SUAutomaticallyUpdate = false`; the app clears any stale automatic-download
preference before starting Sparkle. The updater refuses to start if either
setting or its HTTPS feed, public key, signed-feed requirement, pre-extraction
signature check, or sandbox installer setting is missing. Signed-feed failure
expiration is `0`, so an unsigned or tampered appcast never becomes eligible
after a waiting period. Public and staging builds require HTTPS. The
`FOLIO_UPDATE_TEST` compilation flag alone permits `http://127.0.0.1` for a
disposable fixture. That fixture has its own bundle ID, preferences, and
`Folio Update Test` support directory.

Public keys are in `packaging/update-public-keys.json`. Their matching private
keys remain in Keychain accounts `wtf.pippo.folio.public` and
`wtf.pippo.folio.staging`. Never export private keys into the repository, put
them in command arguments, or place signing credentials on the feed host.
Back up the keys securely outside this repository; without them, signed-feed
validation cannot be recovered by waiting.

The default feed URLs are:

- Public: `https://raw.githubusercontent.com/pippo-wtf/folio/main/updates/public.xml`
- Staging: `https://raw.githubusercontent.com/pippo-wtf/folio/main/updates/staging.xml`

The URLs must contain signed appcasts before a release that enables the updater
is distributed. Keep the public and staging archive sets separate. A staged
release must not point at the public feed. Feed hosting and GitHub release
publication require an explicit release decision.

## Build and notarize a release candidate

Set `CFBundleShortVersionString` in `packaging/Info.plist` and use a strictly
increasing numeric `CFBundleVersion`. The prepared local candidate is
`0.13.0` / `2026092403`; the shipped `0.12.3` artifact is immutable.

```sh
FOLIO_DISTRIBUTION=1 \
FOLIO_CODESIGN_IDENTITY='Developer ID Application: Philip Scholl (D683769MKC)' \
FOLIO_BUILD_VERSION=2026092403 \
zsh scripts/package.sh public
zsh scripts/notarize.sh dist/Folio.app
FOLIO_CODESIGN_IDENTITY='Developer ID Application: Philip Scholl (D683769MKC)' \
FOLIO_NOTARIZE_INSTALLER=1 zsh scripts/installer.sh
codesign --force --sign 'Developer ID Application: Philip Scholl (D683769MKC)' \
  --options runtime --timestamp dist/Folio.dmg
zsh scripts/notarize.sh dist/Folio.dmg
```

The notarization script reads the `FolioNotary` Keychain profile by default;
`FOLIO_NOTARY_PROFILE` can select another profile. It submits and staples only
the explicitly named artifact. Packaging never submits to Apple or publishes a
feed. The local `.app`, DMG, and feed are release candidates until their final
signatures, notarization tickets, download URLs, and an upgrade from the
previous version have been verified.

For each channel, put the final notarized archive and a same-stem `.md` release
note in a dedicated directory. Run Sparkle's pinned `generate_appcast` from
`.build/<channel>/artifacts/sparkle/Sparkle/bin/` with the matching Keychain
`--account`, `--download-url-prefix` for the final HTTPS archive location, and
`-o` for the channel appcast. This signs the archive, release notes, and feed.
Do not edit signed XML or notes afterward; regenerate signatures if content
changes. Verify the archive URL and the new build number before publishing.
Do not use `--link` or an information-only item in place of an installable
archive.

## Prepared 0.13.0 local candidates

`dist/Folio.app` and `dist/Folio Staging.app` are Developer ID signed, notarized,
stapled, and accepted by Gatekeeper. `dist/Folio.dmg` is a separate public
installer: its only root app is the signed and stapled `Install Folio.app`,
which carries the notarized Folio payload inside its signed Resources. The
helper verifies both source and copied payload, then installs to the
receiving user’s `~/Applications/Folio.app`; it does not require an
administrator password. The outer DMG is also signed, notarized, and stapled.

Sparkle uses separate app-only ZIPs, not the installer DMG:
`dist/update-public/Folio-0.13.0.zip` and
`dist/update-staging/Folio-Staging-0.13.0.zip`. Each ZIP contains only its
channel’s stapled app. `updates/public.xml` and `updates/staging.xml` are
separately signed appcasts with signed same-stem Markdown release notes.
Feed, archive, and note signatures were verified for each channel, and
three tampered copies per channel were rejected. All SHA-256 hashes, sizes,
intended URLs, four Apple submission IDs, and source hashes for the installer,
default-app prompt, transaction, packaging, and updater are in
`updates/release-0.13.0.json`.

The public appcast expects its ZIP and notes as assets on GitHub tag
`v0.13.0`; that tag also needs `Folio.dmg` for first-time installation.
Staging expects its ZIP and notes on `v0.13.0-staging`. These assets and
feeds are not published yet. Preserve the exact candidate bytes in the
manifest; changing an archive, note, or XML requires regenerated signatures
and hashes. Do not publish either feed before its referenced assets exist at
the exact signed URLs.

The Homebrew cask must switch to the **public app-only ZIP** for 0.13.0;
the installer DMG now has only the helper at its root. Keep the cask and
README on the shipped version until release approval. At that point, update
the README Homebrew command to include `--appdir="$HOME/Applications"` so it
matches the personal installation target. A clean-Mac installer pass and a
published-feed upgrade remain manual release gates.

## Isolated local upgrade test

`FOLIO_CODESIGN_IDENTITY='Developer ID Application: Philip Scholl (D683769MKC)' zsh scripts/prepare-update-test.sh`
creates two Developer ID signed test apps under a new `/private/tmp/folio-update-test.*`
directory. The old app has build `990001`; the signed archive has build
`990002`. The script signs a feed and release notes with the staging test key,
then prints exact commands to serve the feed on loopback and launch the old
bundle. It does not launch, install, notarize, or publish anything. Only the
test bundle accepts loopback HTTP; this avoids modifying the user's public or
staging app and their data. Its storage path is distinct from both.

A human acceptance pass should confirm that automatic checking only announces
the newer build and shows the notes; no archive downloads before **Update**.
After **Update**, confirm the app quits through the existing unsaved-edit
confirmation, installs the signed build, relaunches, and reports `990002` at
the original test path. Canceling the unsaved-edit prompt must leave the old
app and draft intact. Run `python3 scripts/verify-update-test-signatures.py /private/tmp/folio-update-test.XXXXXX`
with the fixture path printed by the preparation script. This checks the original feed, archive, and notes, then
rejects three tampered copies made under `/private/tmp` without touching the
running app or server. Do not infer UI behavior from a successful build or
signature check; record actual UI and filesystem evidence.

Official references: [Sparkle setup](https://sparkle-project.org/documentation/),
[customization and signed-feed policy](https://sparkle-project.org/documentation/customization/),
[sandboxing](https://sparkle-project.org/documentation/sandboxing/), and
[Apple local network ATS](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).
