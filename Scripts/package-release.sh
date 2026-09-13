#!/usr/bin/env bash
# Validate and archive an existing app. Does not build, sign, upload, or publish.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
: "${RELEASE_TAG:?Set RELEASE_TAG=vX.Y.Z explicitly}"
: "${EXPECTED_VERSION:?Set EXPECTED_VERSION explicitly}"
: "${EXPECTED_BUILD_NUMBER:?Set EXPECTED_BUILD_NUMBER explicitly}"
[[ "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$EXPECTED_BUILD_NUMBER" =~ ^[0-9]+$ ]] || exit 2
[[ "$RELEASE_TAG" == "v$EXPECTED_VERSION" ]] || { echo 'Tag/version mismatch.' >&2; exit 2; }
# CI branch builds may supply a prospective tag. On actual tag builds verify it too.
if [[ "${GITHUB_REF_TYPE:-}" == tag && "${GITHUB_REF_NAME:-}" != "$RELEASE_TAG" ]]; then
    echo 'GitHub tag does not match packaged version.' >&2; exit 2
fi
app="${APP_DIR:-$ROOT/dist/VBAN Receiver.app}"
[[ "$app" = /* ]] || app="$ROOT/$app"
output="${ARCHIVE_DIR:-$ROOT/dist}"
[[ "$output" = /* ]] || output="$ROOT/$output"
bash Scripts/validate-app.sh "$app"
mkdir -p "$output"
# Unique staging protects existing published/downloaded archives from overwrite.
staging="$(mktemp -d "$output/release-check.XXXXXX")"
archive="VBAN-Receiver-$RELEASE_TAG-build$EXPECTED_BUILD_NUMBER-macos.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/$archive"
unzip -tq "$staging/$archive"
mkdir "$staging/extracted"
ditto -x -k "$staging/$archive" "$staging/extracted"
bash Scripts/validate-app.sh "$staging/extracted/$(basename "$app")"
(cd "$staging" && shasum -a 256 "$archive" > "$archive.sha256" && shasum -a 256 -c "$archive.sha256")
# Only delete our temporary extraction, never the input app.
rm -rf "$staging/extracted"
printf 'Verified archive: %s/%s\n' "$staging" "$archive"
