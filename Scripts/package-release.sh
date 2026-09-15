#!/usr/bin/env bash
# Validate and archive an existing app. Does not build, sign, upload, or publish.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export BUILD_KIND="${BUILD_KIND:-development}"
export EXPECTED_BUILD_KIND="$BUILD_KIND"
if [[ "$BUILD_KIND" == release ]]; then
    : "${RELEASE_TAG:?Set RELEASE_TAG=vX.Y.Z explicitly for a release archive}"
    export EXPECTED_RELEASE_TAG="$RELEASE_TAG"
elif [[ -n "${RELEASE_TAG:-}" ]]; then
    echo 'Development archives cannot claim RELEASE_TAG.' >&2; exit 2
fi
app="${APP_DIR:-$ROOT/dist/VBAN Receiver.app}"
[[ "$app" = /* ]] || app="$ROOT/$app"
output="${ARCHIVE_DIR:-$ROOT/dist}"
[[ "$output" = /* ]] || output="$ROOT/$output"
archive="$(python3 -B Scripts/build-metadata.py archive-name "$app" --current-source)"
bash Scripts/validate-app.sh "$app"
mkdir -p "$output"
# Unique output directories never overwrite earlier archives, even for the same tag.
staging="$(mktemp -d "$output/archive-check.XXXXXX")"
ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/$archive"
unzip -tq "$staging/$archive"
mkdir "$staging/extracted"
ditto -x -k "$staging/$archive" "$staging/extracted"
bash Scripts/validate-app.sh "$staging/extracted/$(basename "$app")"
(cd "$staging" && shasum -a 256 "$archive" > "$archive.sha256" && shasum -a 256 -c "$archive.sha256")
rm -rf "$staging/extracted"
printf 'Verified archive: %s/%s\n' "$staging" "$archive"
