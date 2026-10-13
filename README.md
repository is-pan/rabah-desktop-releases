# Rabah Desktop Releases

Official binary release archive for **Rabah Desktop** on macOS and Windows.
The former repository name redirects here. Historical tags and asset names
retain the product name used when those versions shipped.

The application source is maintained in a private repository. This public
repository contains release metadata and downloadable installer assets only.

## Current status

There is no generally supported public stable build yet. Existing releases are
historical internal-test builds preserved for traceability and are marked as
pre-releases.

Do not install a historical build unless you are reproducing an old test. Old
builds may contain known login, background-service, Codex integration, update,
or security limitations.

## Platforms

- Windows x64: NSIS setup executable (`*-setup.exe`)
- macOS Apple silicon: disk image (`*.dmg`), where an original disk image was
  retained

Some early releases are available only for Windows. Missing versions or
platforms were not reconstructed from installed applications.

## Integrity and signing

Each release includes a `SHA256SUMS` file. Verify the checksum before using an
installer.

Windows installers are not Authenticode signed. Recent macOS packages use
Developer ID distribution signing, hardened runtime, notarization and stapling;
some early historical packages used Apple Development signing. Consult the
release notes and verify the package's actual signature before installing.

## Download policy

- GitHub Releases: permanent version archive and fallback download source
- `download.rabah.ai`: primary download source for the latest complete macOS +
  Windows version only

The website download page is `https://www.rabah.ai/download/`.
The new fixed download paths are:

- `https://download.rabah.ai/latest/Rabah-Desktop-Windows-x64-setup.exe`
- `https://download.rabah.ai/latest/Rabah-Desktop-macOS-arm64.dmg`
- `https://download.rabah.ai/latest/SHA256SUMS.txt`
- `https://download.rabah.ai/desktop/latest.json`

Rabah Desktop checks the signed Tauri updater manifest at
`https://download.rabah.ai/desktop/updater/latest.json`. Release assets must
also contain the Windows installer signature and the signed macOS app archive;
the R2 workflow rejects incomplete updater releases.

The `desktop/latest.json` manifest points at immutable, versioned R2 object URLs and
includes each installer's SHA-256 digest and byte size. GitHub Actions selects
the highest semantic version that has both platform installers and a checksum
file. This includes pre-releases while Rabah Desktop remains in testing.

The `rabah-desktop-downloads` bucket retains only the selected Desktop version.
Older installers remain available from GitHub Releases. During the bucket
migration every existing object, including third-party mirrors and the frozen
legacy `/updater/latest.json`, is copied and checked before the domain moves.
Legacy `Rabah-Companion-*` paths remain unchanged for existing downloads.
The old bucket is retained until a separate cleanup confirmation.

## ChatGPT Desktop mirror

Rabah Desktop installs ChatGPT Desktop from `https://download.rabah.ai/codex/`
only; the scheduled workflow is the one component that contacts OpenAI.

- `codex/latest.json` lists each platform with its own version, the versioned
  immutable object URL, SHA-256 and byte size. The Windows version is the MSIX
  manifest's; the macOS version is read from the app inside the DMG.
- The workflow runs on macOS. Before publishing it checks the MSIX identity
  and architecture, and that the DMG's app is `com.openai.codex`, signed by
  OpenAI (team `2DC432GLL2`) with an intact signature, and has an arm64
  slice. Every upload is read back and compared before the catalog changes.
- A scheduled run skips only when both platform versions match upstream and
  every catalog object in R2 has its catalog size and SHA-256; otherwise it
  mirrors again, so a missing or damaged object repairs itself.
- R2 keeps the current and the previous version, so a download that started
  from the previous catalog is not cut off by a publish.

## Security

Never download Rabah Desktop from an unlisted third-party mirror. Release
assets are immutable; a corrected build receives a new version instead of
silently replacing an existing file.
