# Distributing Kvist

Kvist's supported public release path is a Developer ID-signed and notarized
direct download for macOS 26 or later.

## Prerequisites

- An active Apple Developer Program membership.
- A `Developer ID Application` certificate in the login keychain.
- A notarytool keychain profile created once with:

  ```sh
  xcrun notarytool store-credentials kvist-notary
  ```

## Create a release

Run:

```sh
Scripts/release.sh
```

The script locates the Developer ID Application identity, builds the app,
enables the hardened runtime, signs with a secure timestamp, submits a ZIP to
Apple's notary service, staples the accepted ticket to the app, recreates the
ZIP, and verifies the final artifact. It then builds a drag-to-Applications
disk image from the stapled app (`Scripts/dmg.sh`), signs it, and notarizes
and staples the disk image as its own artifact. The release produces both
`dist/Kvist.zip` and `dist/Kvist.dmg`.

The disk image's Finder window layout is written by Finder itself, so
`Scripts/dmg.sh` requires a logged-in GUI session and Automation permission
for Finder; it cannot run headless.

To select a particular identity or notary profile:

```sh
KVIST_SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)" \
KVIST_NOTARY_PROFILE="kvist-notary" \
Scripts/release.sh
```

## Publish the release

Releases are built and published from this Mac. There is no CI workflow.

1. Pick the version. A release with new features bumps the minor version, and
   a fix-only release bumps the patch. Confirm the current version in
   `Resources/Info.plist` before you choose.
2. In `Resources/Info.plist`, set `CFBundleShortVersionString` to the new
   version and add 1 to the integer `CFBundleVersion`. Edit the two strings in
   place. `plutil -replace` rewrites the whole file's formatting.
3. Run `swift test`, then commit as `chore: prepare Kvist X.Y.Z release` and
   push `main`.
4. Run `Scripts/release.sh`. It takes a few minutes because it notarizes twice,
   so run it in the background and watch its output.
5. Publish both artifacts. `gh` creates the `macos/X.Y.Z` tag on GitHub, so
   fetch it afterwards:

   ```sh
   gh release create "macos/X.Y.Z" dist/Kvist.zip dist/Kvist.dmg \
     --target main --title "Kvist X.Y.Z" --notes-file notes.md
   git fetch --tags
   ```

6. Do not install the release build into `/Applications`. The installed copy
   stays on the old version so the user can test the updater against the new
   release.

Release notes follow the shape of `gh release view macos/0.5.0`. Start with a
paragraph on what the release adds and a list of changes. Then add "Update
from Kvist X.Y using Kvist > Check for Updates. Requires macOS 26 or later.
Both downloads are signed with Developer ID and notarized by Apple." End with
the SHA-256 of each artifact (`shasum -a 256 dist/Kvist.zip dist/Kvist.dmg`)
and a "Full changelog" compare link from the previous tag.

Installed copies find the release through the conditions below.

## In-app updates

Kvist checks the GitHub releases of `hkarlsen06/Kvist` and offers the newest
release that meets all of these conditions:

- It is published and is not a prerelease.
- Its tag is `macos/<version>`, and `<version>` is greater than the running
  app's `CFBundleShortVersionString`.
- It has a `Kvist.zip` asset whose app has that same version.

Kvist installs the archive only if the downloaded app satisfies the running
app's designated requirement. Sign every release with the same Developer ID
team, or installed copies will refuse the update. Ad-hoc-signed local builds
cannot update themselves.

`Scripts/package.sh` intentionally creates an ad-hoc-signed local development
build when `KVIST_SIGNING_IDENTITY` is not set. Do not distribute that build.

The release ZIP contains Kvist's license, privacy notice, and third-party
notices inside the app bundle. Update those documents whenever dependencies or
data flows change.
