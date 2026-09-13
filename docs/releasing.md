# Building and releasing

The committed macOS baseline is **0.3.13 (build 17)**, defined once in
[`VERSION.env`](../VERSION.env). Unreleased working-tree features and local test
builds are not proof of a published release. The authoritative published versions
and downloadable assets are on [GitHub Releases](https://github.com/XiaoLeXLDW/vban-receiver-mac/releases).

## Development and CI

On macOS 13 or newer with Xcode Command Line Tools, Python 3, and the macOS SDK:

```sh
make validate-docs
make test-unit BUILD_DIR=.build/check
make app BUILD_DIR=.build/check DIST_DIR=dist/check
make validate-app APP_PATH='dist/check/VBAN Receiver.app' EXPECTED_VERSION=0.3.13 EXPECTED_BUILD_NUMBER=17
```

`ARCH=arm64` is the default; a universal package can use `ARCH="arm64 x86_64"`.
Unit tests include local UDP/socket tests and mocked audio-policy checks. Live playback and listening checks must be performed separately on a suitable
test Mac; this public baseline has no automated hardware-runtime target. CI does not claim speaker, network latency, live Windows
sync, or listening coverage. It does not launch or install the application.

[`validate.yml`](../.github/workflows/validate.yml) checks committed inputs and
local documentation links, runs `test-unit`, packages an ad-hoc app, and verifies
its metadata, architectures, minimum OS, resources and signature. It then checks
ZIP integrity, revalidates the extracted bundle and creates/verifies SHA-256.
Failures stop artifact publication; Actions records the failed job. Uploaded
Actions artifacts are test outputs, not a GitHub Release. No deployment, traffic
switch, automatic release or production rollback occurs in this workflow.

The local link checker checks relative Markdown/image/reference/HTML file paths
in root documents, `docs`, `Tools`, and `.github`. It intentionally does not
validate remote websites or heading fragments. Screenshot existence does not
prove that its UI matches the current application.

## Prepare a release commit

1. Review all intended source, test, resource, script and documentation changes.
   Keep machine logs, recordings, temporary builds and private configuration out
   of the commit. Preserve historical release tags and useful design evidence.
2. Set `DEFAULT_VERSION` and `DEFAULT_BUILD_NUMBER` in `VERSION.env` to the
   intended release, then update both READMEs and the [changelog](../CHANGELOG.md).
   Use an unused version/tag for new development; do not republish the baseline
   version with different content.
3. Commit the reviewed files. Run `make validate-release-tree` and the checks
   above against that commit. This gate rejects required untracked/ignored
   inputs, working-tree changes and staged but uncommitted release inputs. It
   never stages files or bypasses missing source files.
4. Create the matching `vX.Y.Z` tag only after checks pass. Record manual audio
   results and clearly label the signature status in the release notes.
5. Archive the verified app and upload its ZIP plus `.sha256` to the intended
   release. Keep the previous known-good release available for users to revert.

`make release-archive RELEASE_TAG=v0.3.13 DIST_DIR=dist/check` validates an existing
app against the chosen version/build and creates a new `release-check.*` directory
without overwriting earlier archives. For a new release, use its new version.
Tag-triggered CI additionally rejects a tag that differs from `VERSION.env`.
Branch CI checks the prospective tag string; it does not claim that tag exists
or the artifact has been released. Release-tree validation is separate and must
pass before any actual release.

## Signature and distribution modes

| Mode | Package | Required check | Release description |
| --- | --- | --- | --- |
| Community build | Default `SIGN_IDENTITY=-` | `make validate-app` plus explicit expected version/build | Ad-hoc signed; not Developer ID signed or notarized; macOS may block opening |
| Developer ID distribution | `SIGN_IDENTITY='Developer ID Application: …' make app` | Notarize, staple, then `make validate-release` with explicit expected version/build | Claim notarization only after the strict gate passes |

Ad-hoc signing provides bundle integrity, not publisher identity or notarization.
Community builds can be shared with that limitation clearly stated. Do not call
an ad-hoc build notarized or Apple-approved. The strict gate checks Developer ID,
Gatekeeper acceptance and a stapled notarization ticket. It does not build or
change the artifact. CI uses no signing credentials and cannot prove this gate.

For the strict path, submit the signed ZIP using a locally configured notarytool
keychain profile, staple the accepted app, then validate and archive it:

```sh
xcrun notarytool submit signed-upload.zip --keychain-profile YOUR_PROFILE --wait
xcrun stapler staple 'dist/check/VBAN Receiver.app'
make validate-release APP_PATH='dist/check/VBAN Receiver.app' EXPECTED_VERSION=0.3.13 EXPECTED_BUILD_NUMBER=17
STRICT_RELEASE=1 make release-archive RELEASE_TAG=v0.3.13 DIST_DIR=dist/check
```

Replace the example baseline values with the intended new release version/build.
Store certificates and credentials in Keychain or protected CI secrets, never in
the repository. Check the checksum after downloading an uploaded asset as the
final transport check.
