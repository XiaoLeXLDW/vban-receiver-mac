# Building and releasing

[`VERSION.env`](../VERSION.env) is the single committed target for the numeric
version and build number. It currently records 0.3.14 (18). This does not make
subsequent source changes a new release. Published downloads are listed on
[GitHub Releases](https://github.com/XiaoLeXLDW/vban-receiver-mac/releases).

## Development builds

On macOS with Xcode Command Line Tools, Python 3 and Git, run:

```sh
make validate-docs
make test-unit test-packaging BUILD_DIR=.build/check
make app BUILD_DIR=.build/check DIST_DIR=dist/check
make validate-app APP_PATH='dist/check/VBAN Receiver.app'
make archive DIST_DIR=dist/check
```

Local and branch builds default to `BUILD_KIND=development`. The app display name
includes Dev; About shows DEVELOPMENT, architecture, the short commit and a dirty
marker when uncommitted changes exist. Numeric `CFBundleShortVersionString` and
`CFBundleVersion` remain valid macOS version fields. The signed bundle contains
`Contents/Resources/build-info.json` with the full commit, build kind, version,
build number, architectures and dirty flag. The archive name resembles
`VBAN-Receiver-dev-arm64-abcdef123456-macos.zip` (with `-dirty` when applicable).
A dirty build identifies a development checkout, not a reproducible committed release.

`ARCH=arm64` is the default; use `ARCH="arm64 x86_64"` for a universal build.
`make app` may replace an existing identified development bundle. It refuses to
overwrite a release or an old bundle without build identity; select a fresh
`DIST_DIR` or `APP_PATH` in that case. It does not install or open the app.

`make archive` validates the existing bundle, checks its recorded commit and dirty
flag against the current checkout, creates a unique `archive-check.*` directory,
verifies the ZIP, checks the extracted app and writes/verifies SHA-256. It never
rebuilds the app or overwrites an earlier archive. Rebuild after committing changes
before archiving. Always distribute the ZIP and its matching `.sha256` together.

## Prepare a release

1. Review and commit the intended source, tests, resources and documentation.
   Keep private logs, recordings and temporary files out of the commit. Retain
   historical tags, release assets and design evidence.
2. Update `VERSION.env` to an unused version and build number, update the
   changelog and download instructions, and commit the change.
3. Run the checks above and `make validate-release-tree` on the clean commit.
   This gate rejects required untracked inputs, unstaged changes and staged but
   uncommitted inputs. It never stages files itself.
4. After checks pass, create the corresponding `vX.Y.Z` tag on that exact commit.
   Record manual audio validation separately from automated checks.
5. Build and archive with explicit release identity as shown below. Upload only
   the verified output and checksum to the new release, stating signature status.

For example, after committing 0.3.15 / build 19 in `VERSION.env` and creating
`v0.3.15` on that commit (example values, not a current release):

```sh
make app BUILD_KIND=release RELEASE_TAG=v0.3.15 DIST_DIR=dist/release-0.3.15
make validate-app APP_PATH='dist/release-0.3.15/VBAN Receiver.app' EXPECTED_VERSION=0.3.15 EXPECTED_BUILD_NUMBER=19
make release-archive BUILD_KIND=release RELEASE_TAG=v0.3.15 DIST_DIR=dist/release-0.3.15
```

Release mode requires a clean checkout, numeric metadata matching `VERSION.env`,
and an existing version tag pointing to the packaged commit. A branch build
cannot borrow the old v0.3.13 tag to claim release identity. Release bundle outputs
are not replaced. These commands do not upload or publish anything.

## Signing and historical bundles

Build kind and signature status are separate. The default `SIGN_IDENTITY=-` gives
an ad-hoc signature: bundle integrity, without publisher identity or notarization.
Community release notes must state this limitation.

For Developer ID distribution, build with your `SIGN_IDENTITY`, submit the signed
ZIP to `xcrun notarytool` using a configured Keychain profile, staple the accepted
app, then run `make validate-release` with explicit expected version/build. Use
`STRICT_RELEASE=1 make release-archive BUILD_KIND=release RELEASE_TAG=...` to
recheck that gate while archiving. The strict gate requires release provenance,
Developer ID signing, Gatekeeper acceptance and a stapled ticket. Credentials
belong in Keychain or protected CI secrets, never the repository.

Historical downloads such as v0.3.13 predate build provenance. Ordinary
`make validate-app` can still check their metadata, architecture and signature
integrity, while clearly reporting that build provenance is unavailable. This
legacy path does not apply to partial or inconsistent new metadata, and cannot
be used for new archives or strict release validation. Keep old assets unchanged.

## CI and evidence

[`validate.yml`](../.github/workflows/validate.yml) runs the committed-input gate,
local documentation checks, unit/UI-state tests, packaging regression tests, app
build, bundle validation and ZIP/SHA-256 roundtrip checks. Branch and pull-request
artifacts are development builds; tag builds explicitly request release mode.
The artifact records the checked-out commit (for PRs, GitHub's tested merge commit).
Actions artifacts are validation outputs, not published Releases.

UI-state tests run offscreen and do not open an audio device. Automated checks do
not establish audible playback quality, real-world latency or notarization.
Manual listening checks remain separate. The documentation checker checks local
file targets, not external URLs or heading fragments.

The [runtime contract](../CONTEXT.md) is required by release-tree validation;
renaming it must update that gate and its links. Historical measurements should
record commit, hardware, macOS, toolchain, command, sampling method and limitations.
