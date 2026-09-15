#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="VBAN Receiver"
BINARY_NAME="VBANReceiver"
APP_DIR="${APP_DIR:-$ROOT/dist/$APP_NAME.app}"
[[ "$APP_DIR" = /* ]] || APP_DIR="$ROOT/$APP_DIR"
if [[ "$APP_DIR" != *.app || -L "$APP_DIR" ]]; then
    echo 'APP_DIR must name an app bundle, not a symlink or workspace directory.' >&2
    exit 2
fi
BUILD_DIR="${BUILD_DIR:-.build}"
[[ "$BUILD_DIR" = /* ]] || BUILD_DIR="$ROOT/$BUILD_DIR"
BUILD_BIN="${BUILD_BIN:-$BUILD_DIR/$BINARY_NAME}"
[[ "$BUILD_BIN" = /* ]] || BUILD_BIN="$ROOT/$BUILD_BIN"
export BUILD_KIND="${BUILD_KIND:-development}"
export ARCH="${ARCH:-arm64}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# Refuse invalid release identities before building or changing any bundle.
python3 -B "$ROOT/Scripts/build-metadata.py" check-inputs
if [[ -e "$APP_DIR" ]]; then
    # Only our explicitly marked development bundles can be replaced by a dev build.
    if [[ "$BUILD_KIND" != development ]] ||
        ! env -u ARCH -u EXPECTED_VERSION -u EXPECTED_BUILD_NUMBER -u EXPECTED_COMMIT -u EXPECTED_RELEASE_TAG \
            EXPECTED_BUILD_KIND=development python3 -B "$ROOT/Scripts/build-metadata.py" validate "$APP_DIR" >/dev/null; then
        echo 'Refusing to overwrite an existing release or unidentified app. Choose a new APP_DIR/DIST_DIR.' >&2
        exit 2
    fi
fi

if [[ "${SKIP_BUILD:-0}" != 1 ]]; then
    make -C "$ROOT" build BUILD_DIR="$BUILD_DIR" ARCH="$ARCH"
fi
[[ -f "$BUILD_BIN" ]] || { echo "Built binary not found: $BUILD_BIN" >&2; exit 2; }

mkdir -p "$(dirname "$APP_DIR")"
staging="$(mktemp -d "$(dirname "$APP_DIR")/.vban-package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
staged_app="$staging/$APP_NAME.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$BUILD_BIN" "$staged_app/Contents/MacOS/$BINARY_NAME"
chmod +x "$staged_app/Contents/MacOS/$BINARY_NAME"
# The release tree must already contain the icon; packaging does not mutate source resources.
cp "$ROOT/Resources/AppIcon.icns" "$staged_app/Contents/Resources/AppIcon.icns"
cp "$ROOT/LICENSE" "$staged_app/Contents/Resources/LICENSE.txt"
python3 -B "$ROOT/Scripts/build-metadata.py" write "$staged_app"

if [[ "$SIGN_IDENTITY" == - ]]; then
    codesign --force --deep --sign - "$staged_app" >/dev/null
    echo "Signed ad-hoc ($BUILD_KIND); not Developer ID signed or notarized." >&2
else
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$staged_app" >/dev/null
    echo "Signed with '$SIGN_IDENTITY'; notarize and staple before claiming Developer ID distribution." >&2
fi
codesign --verify --deep --strict "$staged_app"
python3 -B "$ROOT/Scripts/build-metadata.py" validate "$staged_app" >/dev/null

# A failed build/sign leaves the previous dev app intact. Release outputs are never replaced.
if [[ -e "$APP_DIR" ]]; then mv "$APP_DIR" "$staging/previous.app"; fi
if ! mv "$staged_app" "$APP_DIR"; then
    [[ ! -e "$staging/previous.app" ]] || mv "$staging/previous.app" "$APP_DIR"
    exit 2
fi
echo "$APP_DIR"
