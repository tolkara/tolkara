#!/bin/bash
# Build Tolkara Management, the Mac setup app (management/), for distribution:
# a universal Release build carrying Tolkara's own source, in a disk image.
# usage: tools/package_management.sh [output.dmg]      (default: Tolkara-Management.dmg)
# Signing, all optional (.github/workflows/release.yml passes them from secrets):
#   MANAGEMENT_SIGN_IDENTITY  "Developer ID Application: …" in the keychain: signs
#                             with the hardened runtime instead of ad hoc.
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER  an App Store Connect API key (.p8
#                             path, key ID, issuer ID): also notarizes and staples.
# Without them the app is ad hoc signed, and macOS asks the user to confirm it in
# System Settings › Privacy & Security the first time it is opened.
# The app contains only Tolkara's own code and source: no application, no
# signing material, nothing ignored by git (local.env, build output).
set -euo pipefail
OUT=${1:-Tolkara-Management.dmg}
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT";; esac
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
if [ -z "${TOLKARA_VERSION:-}" ]; then
    TOLKARA_VERSION=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo v0.0); TOLKARA_VERSION=${TOLKARA_VERSION#v}
fi
export TOLKARA_VERSION
mkdir -p logs build
LOG=logs/management-$(date +%Y%m%d-%H%M%S).log
xcodegen generate -q --spec management/project.yml
rm -rf build/management
xcodebuild -project management/TolkaraManagement.xcodeproj -scheme TolkaraManagement -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build/management ONLY_ACTIVE_ARCH=NO \
    build > "$LOG" 2>&1 \
    || { grep -E "error:" "$LOG" | head -20; echo "BUILD FAILED -> $LOG"; exit 1; }
APP="build/management/Build/Products/Release/Tolkara Management.app"
[ -d "$APP" ] || { echo "Build did not produce $APP -> $LOG"; exit 1; }

# What goes out: the source archive holds committed files only.
SOURCE="$APP/Contents/Resources/Tolkara-source.tar.gz"
[ -f "$SOURCE" ] || { echo "Refusing to package: the app carries no Tolkara source."; exit 1; }
if tar -tzf "$SOURCE" | grep -E '(^|/)(local\.env|build|logs)(/|$)|\.(mobileprovision|p12|p8|ipa|dylib)$' | grep -q .; then
    echo "Refusing to package: the source archive carries personal or built files."; exit 1
fi

if [ -n "${MANAGEMENT_SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$MANAGEMENT_SIGN_IDENTITY" "$APP" >> "$LOG" 2>&1
else
    codesign --force --sign - "$APP" >> "$LOG" 2>&1
fi
codesign --verify --strict "$APP" >> "$LOG" 2>&1 || { echo "Signature check failed -> $LOG"; exit 1; }

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/tolkara-management.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Tolkara Management.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "Tolkara Management" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >> "$LOG" 2>&1
if [ -n "${MANAGEMENT_SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$MANAGEMENT_SIGN_IDENTITY" "$OUT" >> "$LOG" 2>&1
    if [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
        xcrun notarytool submit "$OUT" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait >> "$LOG" 2>&1 \
            || { echo "NOTARIZATION FAILED -> $LOG"; exit 1; }
        xcrun stapler staple "$OUT" >> "$LOG" 2>&1
        echo "Notarized."
    fi
fi
echo "Tolkara Management $TOLKARA_VERSION -> $OUT"
