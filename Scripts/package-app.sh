#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="VBAN Receiver"
BINARY_NAME="VBANReceiver"
APP_DIR="${APP_DIR:-$ROOT/dist/$APP_NAME.app}"
if [[ "$APP_DIR" != /* ]]; then APP_DIR="$ROOT/$APP_DIR"; fi
if [[ "$APP_DIR" != *.app || "$APP_DIR" == "$ROOT" ]]; then
    echo 'APP_DIR must name an app bundle, not a workspace directory.' >&2
    exit 2
fi
BUILD_DIR="${BUILD_DIR:-.build}"
if [[ "$BUILD_DIR" != /* ]]; then BUILD_DIR="$ROOT/$BUILD_DIR"; fi
BUILD_BIN="${BUILD_BIN:-$BUILD_DIR/$BINARY_NAME}"
if [[ "$BUILD_BIN" != /* ]]; then BUILD_BIN="$ROOT/$BUILD_BIN"; fi
requested_version="${VERSION:-}"
requested_build="${BUILD_NUMBER:-}"
source "$ROOT/VERSION.env"
VERSION="${requested_version:-$DEFAULT_VERSION}"
BUILD_NUMBER="${requested_build:-$DEFAULT_BUILD_NUMBER}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || {
    echo "VERSION must be x.y.z and BUILD_NUMBER must be an integer." >&2
    exit 2
}
ARCH="${ARCH:-arm64}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    make -C "$ROOT" build BUILD_DIR="$BUILD_DIR" ARCH="$ARCH" VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER"
fi

if [[ ! -f "$BUILD_BIN" ]]; then
    echo "Built binary not found: $BUILD_BIN" >&2
    exit 2
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_BIN" "$APP_DIR/Contents/MacOS/$BINARY_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$BINARY_NAME"

if [[ ! -f "$ROOT/Resources/AppIcon.icns" && -f "$ROOT/Resources/AppIconSource.png" && -x "$ROOT/Scripts/build-app-icon.py" ]]; then
    (cd "$ROOT" && "$ROOT/Scripts/build-app-icon.py" >/dev/null)
fi
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
cp "$ROOT/LICENSE" "$APP_DIR/Contents/Resources/LICENSE.txt"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$BINARY_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>local.codex.vban-receiver</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Receive VBAN audio streams from VoiceMeeter on your local network.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        codesign --force --deep --sign - "$APP_DIR" >/dev/null
        echo "Signed ad-hoc; community build is not Developer ID signed or notarized." >&2
    else
        codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
        echo "Signed with '$SIGN_IDENTITY'; notarize and staple before claiming Developer ID distribution." >&2
    fi
fi

echo "$APP_DIR"
