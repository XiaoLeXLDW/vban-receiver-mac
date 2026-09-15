#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="${1:-dist/VBAN Receiver.app}"
app_name="${APP_NAME:-VBAN Receiver}"
binary_name="${BINARY_NAME:-VBANReceiver}"
architectures="${ARCH:-arm64}"
expected_version="${EXPECTED_VERSION:-}"
expected_build_number="${EXPECTED_BUILD_NUMBER:-}"
strict_release="${STRICT_RELEASE:-0}"

fail() {
    echo "App validation failed: $*" >&2
    exit 2
}

if [[ "$strict_release" != "0" && "$strict_release" != "1" ]]; then
    fail "STRICT_RELEASE must be 0 or 1 (received '$strict_release')."
fi
if [[ "$strict_release" == "1" && ( -z "$expected_version" || -z "$expected_build_number" ) ]]; then
    fail "strict release validation requires EXPECTED_VERSION and EXPECTED_BUILD_NUMBER."
fi

if [[ ! -d "$app_path" ]]; then
    fail "app bundle does not exist: $app_path"
fi

info_plist="$app_path/Contents/Info.plist"
binary_path="$app_path/Contents/MacOS/$binary_name"

if [[ ! -f "$info_plist" ]]; then
    fail "Info.plist does not exist: $info_plist"
fi
if [[ ! -x "$binary_path" ]]; then
    fail "app executable is missing or is not executable: $binary_path"
fi

for resource in AppIcon.icns LICENSE.txt; do
    [[ -s "$app_path/Contents/Resources/$resource" ]] || fail "required resource missing: $resource"
done

plutil -lint "$info_plist"
if [[ "$strict_release" == 1 ]]; then
    EXPECTED_BUILD_KIND=release python3 -B "$ROOT/Scripts/build-metadata.py" validate "$app_path" --current-source
else
    python3 -B "$ROOT/Scripts/build-metadata.py" validate "$app_path" --allow-legacy
fi

actual_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$info_plist" 2>/dev/null)" ||
    fail "CFBundleName is missing from $info_plist"
if [[ "$actual_name" != "$app_name" ]]; then
    fail "expected CFBundleName '$app_name', found '$actual_name'."
fi

actual_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist" 2>/dev/null)" ||
    fail "CFBundleExecutable is missing from $info_plist"
if [[ "$actual_executable" != "$binary_name" ]]; then
    fail "expected CFBundleExecutable '$binary_name', found '$actual_executable'."
fi

actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null)" ||
    fail "CFBundleShortVersionString is missing from $info_plist"
actual_build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist" 2>/dev/null)" ||
    fail "CFBundleVersion is missing from $info_plist"
minimum_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info_plist" 2>/dev/null)" ||
    fail "LSMinimumSystemVersion is missing from $info_plist"
if [[ ! "$minimum_os" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    fail "invalid LSMinimumSystemVersion '$minimum_os'."
fi

if [[ -n "$expected_version" && "$actual_version" != "$expected_version" ]]; then
    fail "expected version '$expected_version', found '$actual_version'."
fi
if [[ -n "$expected_build_number" && "$actual_build_number" != "$expected_build_number" ]]; then
    fail "expected build number '$expected_build_number', found '$actual_build_number'."
fi

read -r -a architecture_list <<< "$architectures"
if [[ "${#architecture_list[@]}" -eq 0 ]]; then
    fail "ARCH must contain at least one architecture."
fi
for architecture in "${architecture_list[@]}"; do
    if [[ ! "$architecture" =~ ^[A-Za-z0-9_]+$ ]]; then
        fail "invalid architecture '$architecture'."
    fi
done
lipo "$binary_path" -verify_arch "${architecture_list[@]}"

# Compilation flags alone do not constrain the final link deployment target.
# Verify the load command so an app advertising macOS 13 cannot require 15.
for architecture in "${architecture_list[@]}"; do
    build_commands="$(xcrun vtool -arch "$architecture" -show-build "$binary_path")" ||
        fail "could not inspect the $architecture Mach-O deployment target."
    binary_minimum_os="$(awk '$1 == "minos" { print $2; exit }' <<< "$build_commands")"
    if [[ ! "$binary_minimum_os" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
        fail "missing or invalid $architecture Mach-O minimum OS '$binary_minimum_os'."
    fi
    if ! awk -v required="$binary_minimum_os" -v advertised="$minimum_os" '
        BEGIN {
            split(required, r, "."); split(advertised, a, ".");
            for (i = 1; i <= 3; i++) {
                if ((r[i] + 0) < (a[i] + 0)) exit 0;
                if ((r[i] + 0) > (a[i] + 0)) exit 1;
            }
            exit 0;
        }'; then
        fail "$architecture executable requires macOS $binary_minimum_os but Info.plist advertises $minimum_os."
    fi
done

codesign --verify --deep --strict --verbose=2 "$app_path"
signature_details="$(codesign -dvvv "$app_path" 2>&1)" ||
    fail "could not inspect the code signature."

if [[ "$strict_release" == "1" ]]; then
    if grep -q '^Signature=adhoc$' <<< "$signature_details"; then
        fail "the app has an ad-hoc signature; the strict distribution gate requires a Developer ID Application signature."
    fi
    if ! grep -q '^Authority=Developer ID Application:' <<< "$signature_details"; then
        fail "the app is not signed with a Developer ID Application certificate."
    fi
    if ! command -v spctl >/dev/null 2>&1; then
        fail "spctl is required for strict Gatekeeper validation."
    fi
    spctl --assess --type execute --verbose=4 "$app_path"
    if ! command -v xcrun >/dev/null 2>&1; then
        fail "xcrun is required for notarization validation."
    fi
    xcrun stapler validate "$app_path"
    echo "Strict distribution validation passed: Developer ID, Gatekeeper, and stapled notarization verified."
else
    if grep -q '^Signature=adhoc$' <<< "$signature_details"; then
        echo "App validation passed (ad-hoc community build; not Developer ID signed or notarized)."
    else
        echo "App validation passed (signature integrity only; use 'make validate-release' to verify Developer ID distribution)."
    fi
fi

echo "Validated artifact: $app_path"
echo "Version/build: $actual_version ($actual_build_number)"
