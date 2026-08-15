# Releasing AfterRay for macOS

AfterRay ships as one versioned application bundle. The Swift app and every
Rust or Swift helper are built, signed, notarized, and updated together:

```text
AfterRay.app/
└── Contents/
    ├── MacOS/
    │   └── AfterRay
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
daemon protocol versions aligned.

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

The marketing version in `apps/AfterRay/Resources/Info.plist` must match
`workspace.package.version` in `Cargo.toml`. The release script also requires a
clean Git worktree so the artifact maps to one source commit.

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
dependency, signs nested executables from the inside out, enables Hardened
Runtime and a secure timestamp, builds and signs a DMG, submits it with
`notarytool`, staples the ticket, and runs code-signing and Gatekeeper checks.

Outputs are written to `dist/`:

- `AfterRay-<version>-arm64/AfterRay.app`
- `AfterRay-<version>-arm64.dmg`
- `AfterRay-<version>-arm64.dmg.sha256`
- `AfterRay-<version>-arm64.json`

Publish only the notarized DMG and its checksum/manifest. Keep the same signing
identity for later releases so macOS permissions and designated requirements
remain stable across upgrades.

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

## Apple references

- [Create Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
