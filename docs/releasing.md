# Releasing AfterRay for macOS

AfterRay ships as one versioned application bundle. The Swift app and every
Rust or Swift helper are built, signed, notarized, and updated together:

```text
AfterRay.app/
└── Contents/
    ├── MacOS/
    │   └── AfterRay
    ├── Frameworks/
    │   └── Sparkle.framework
    └── Helpers/
        ├── afterrayd
        ├── afterray
        ├── afterray-model-worker
        ├── AfterRayCaptureShim
        └── afterray-native-model-worker
```

Model weights are not part of the application or DMG. The installed app
downloads approved model packs separately. The bundled `afterray` CLI is the
source copied by the in-app **Install CLI** action, which keeps the CLI and
daemon protocol versions aligned; the app refreshes an already-installed copy
at launch whenever the bundled build has moved on.

Installed copies update themselves through Sparkle. See
[Automatic updates](#automatic-updates) below — publishing is a second step
after building, and a release that skips it reaches nobody.

## Prerequisites

- An Apple Silicon Mac with Xcode and the current Rust toolchain.
- A `Developer ID Application` certificate installed in the login Keychain.
- Notarization credentials stored in the Keychain. Store them once with a
  local profile name; do not put credentials in the repository or shell
  history:

  ```sh
  xcrun notarytool store-credentials afterray-notary \
    --apple-id YOUR_APPLE_ID \
    --team-id YOUR_TEAM_ID
  ```

- Sparkle's command-line tools, fetched once per machine:

  ```sh
  make sparkle-tools
  ```

- The EdDSA private key that signs updates, in the login Keychain. See
  [The signing key](#the-signing-key).

The marketing version in `apps/AfterRay/Resources/Info.plist` must match
`workspace.package.version` in `Cargo.toml`. The release script also requires a
clean Git worktree so the artifact maps to one source commit.

`CFBundleVersion` is not maintained by hand. The source plist holds a
placeholder for development builds; the release script stamps the assembled
bundle with the commit count (`git rev-list --count HEAD`), or with
`AFTERRAY_BUILD_NUMBER` when set. Sparkle compares that number and nothing
else, so it must never repeat or go backwards — `publish-release.sh` refuses
both.

## Production release

```sh
AFTERRAY_NOTARY_PROFILE=afterray-notary make release
```

The script auto-detects the first `Developer ID Application` identity. To pick
one explicitly, set `AFTERRAY_CODESIGN_IDENTITY` to its full name or SHA-1:

```sh
AFTERRAY_CODESIGN_IDENTITY='Developer ID Application: Example, Inc. (TEAMID)' \
AFTERRAY_NOTARY_PROFILE=afterray-notary \
make release
```

The default command performs release builds, checks that every binary is
arm64 and has no checkout, Homebrew, `/usr/local`, or unresolved `@rpath`
dependency, signs nested executables from the inside out, and enables Hardened
Runtime and a secure timestamp.

It then notarizes twice, and the order matters. The signed application is
submitted first and its ticket stapled to the bundle; only then is the DMG
built from that stapled app, signed, submitted, and stapled in turn. A ticket
on the DMG alone does not travel with the copy the user drags into
`/Applications`, which leaves their first launch depending on an online check
with Apple. Finally the script runs code-signing and Gatekeeper checks against
both the app and the DMG.

Outputs are written to `dist/`:

- `AfterRay-<version>-arm64/AfterRay.app`
- `AfterRay-<version>-arm64.dmg`
- `AfterRay-<version>-arm64.dmg.sha256`
- `AfterRay-<version>-arm64.zip` — the archive Sparkle downloads
- `AfterRay-<version>-arm64.json`

The zip is packaged **after** the ticket is stapled to the app, and is a
different file from the archive submitted for notarization, which was made
from the unstapled bundle. An update archive without a ticket installs an app
that fails Gatekeeper the first time it launches offline.

Publish only the notarized artifacts and their checksum/manifest. Keep the same
signing identity for later releases so macOS permissions and designated
requirements remain stable across upgrades — a change of identity resets
Screen Recording and Microphone consent for every existing install.

## Local packaging check

This exercises the same release compilation, full app assembly, helper audit,
Hardened Runtime signing, and DMG generation without a Developer ID identity:

```sh
make release-local
```

It permits a dirty worktree and produces an explicitly named
`AfterRay-<version>-local-arm64.dmg`. This artifact is ad-hoc signed, is not
notarized, and must not be published.

To test Developer ID signing before notarization, run:

```sh
./scripts/build-release.sh --skip-notarization
```

That output contains `-unnotarized` in its filename and is also not publishable.

## Automatic updates

Installed copies poll `https://afterray.com/appcast.xml` once a day, download
in the background, and install on the next quit. Nothing is interrupted mid
recording, and a user who never quits still gets critical updates offered
directly.

The feed is not a static file. A Cloudflare Pages Function
(`site/functions/appcast.xml.ts`) renders it from `releases.json` in the
`afterray-releases` R2 bucket, and a second function serves the artifacts from
the same bucket. Publishing is therefore an upload, not a site deploy: shipping
a build cannot break the marketing page, and the page can be redeployed without
touching releases.

### Publishing

```sh
make publish-dry-run   # shows the uploads and the resulting index
make publish           # uploads the zip and DMG, then the index
```

The index is written last, so a failure part way through leaves installed
copies on the previous release rather than pointing them at a partial upload.

`publish-release.sh` refuses to publish an artifact that is not notarized, was
built from a dirty worktree, has no EdDSA signature, or carries a build number
that is already published or older than one that is. Each of those would fail
silently at the user's end rather than at yours.

Mark an urgent release with `--critical` so Sparkle offers it immediately
instead of waiting for the next quit.

### The signing key

Updates are verified with an EdDSA key pair. The public half lives in
`SUPublicEDKey` in `Info.plist`; the private half is in the login Keychain of
whoever publishes.

**Losing the private key means every installed copy stops receiving updates
permanently, and the only remedy is asking users to reinstall by hand.** Export
it and keep the export offline:

```sh
.afterray-dev/sparkle-tools/bin/generate_keys -x afterray-eddsa-private.key
```

To publish from another machine, import it there:

```sh
.afterray-dev/sparkle-tools/bin/generate_keys -f afterray-eddsa-private.key
```

### One-time infrastructure

The R2 bucket must exist and the Pages project must be bound to it. The binding
is declared in `site/wrangler.jsonc`; create the bucket once with:

```sh
cd site && npx wrangler r2 bucket create afterray-releases
```

### Why the app moves itself to /Applications

Sparkle installs an update by replacing the application bundle in place, which
cannot work on the read-only volume a DMG mounts. On first launch from anywhere
outside `/Applications`, AfterRay offers to relocate itself and relaunches from
its new home. Declining is remembered — except on a disk image, where
remembering it would strand the user on a build that can never update.

### Daemon replacement

`afterrayd` outlives the app process briefly on quit, and the app stamps
`AFTERRAY_HOST_BUILD` into its environment. On launch the app compares that
against its own `CFBundleVersion` and restarts a daemon that does not match.
Without this an update that leaves the old daemon holding the socket would run
the new UI against the previous build's logic, against the same store, with
nothing visible to the user.

## Apple references

- [Create Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
