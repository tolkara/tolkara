#!/bin/bash
# The unsigned .ipa a sideloader signs with your Apple ID (ad hoc signed with
# no team, only to declare the memory capabilities it should request).
# usage: tools/package_ipa.sh [output.ipa]        (default: Tolkara-unsigned.ipa)
# Applications are added and started on the iPad in External JIT, preselected:
# the sideloading tool (SideStore or similar), or a JIT enabler such as
# StikDebug, enables JIT. For Developer service or Local signing with your own
# team, build with tools/install.sh instead.
# TOLKARA_SYSTEM_ROOTS=PUBLIC packages Mozilla's public root certificates in
# place of this Mac's (.github/workflows/release.yml does, for the published
# build: nothing exported from macOS is redistributed); NO packages none.
set -euo pipefail
OUT=${1:-Tolkara-unsigned.ipa}
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT";; esac
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
mkdir -p logs build
LOG=logs/ipa-$(date +%Y%m%d-%H%M%S).log
tools/generate.sh
# No extension: a free Apple ID cannot sign one.
# GENERIC: one adapter per framework, no executable.
# Its one way to run code, chosen already.
# By target: schemes need a destination the SDK alone lacks.
xcodebuild -project Tolkara.xcodeproj -target TolkaraDiagnostics -configuration Release \
    -sdk iphoneos -arch arm64 SYMROOT=build/unsigned NATIVE_GUEST_SHIMS=GENERIC TOLKARA_MODE=external-jit \
    TOLKARA_SYSTEM_ROOTS="${TOLKARA_SYSTEM_ROOTS:-YES}" \
    INFOPLIST_KEY_CFBundleDisplayName=Tolkara \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build > "$LOG" 2>&1 \
    || { grep -E "error:" "$LOG" | head -20; echo "BUILD FAILED -> $LOG"; exit 1; }

APP=build/unsigned/Release-iphoneos/TolkaraDiagnostics.app
[ -d "$APP" ] || { echo "Build did not produce $APP -> $LOG"; exit 1; }
# Asked to leave the root certificates out: make sure none were packaged.
if [ "${TOLKARA_SYSTEM_ROOTS:-YES}" = NO ] && [ -n "$(find "$APP" -name CompatibilityRootCertificates.plist -print -quit)" ]; then
    echo "Refusing to package: TOLKARA_SYSTEM_ROOTS=NO, but the build carries root certificates."; exit 1
fi
# A sideloading tool requests the capabilities the app's own signature
# declares: ad hoc, with no team, only to declare the two memory capabilities
# (launcher/App.entitlements). The tool re-signs everything with its own.
for library in "$APP"/Frameworks/*.dylib; do
    [ -f "$library" ] || continue
    codesign -f -s - "$library" >> "$LOG" 2>&1
done
codesign -f -s - --entitlements launcher/App.entitlements "$APP" >> "$LOG" 2>&1
for capability in increased-memory-limit extended-virtual-addressing; do
    codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.developer.kernel.$capability" ||
        { echo "Refusing to package: the app does not declare $capability."; exit 1; }
done
# No identity of ours: no team, no profile embedded.
# No pipe: an early reader would hide the answer.
PROFILE=$(find "$APP" -name embedded.mobileprovision -print -quit)
[ -z "$PROFILE" ] || { echo "Refusing to package: the build embeds a provisioning profile."; exit 1; }
for bundle in "$APP" "$APP"/PlugIns/*.appex; do
    [ -d "$bundle" ] || continue
    # Unsigned, or ad hoc with no team; nothing else.
    if SIGNATURE=$(codesign -dvv "$bundle" 2>&1); then
        TEAM=$(printf '%s\n' "$SIGNATURE" | sed -n 's/^TeamIdentifier=//p')
        case "$TEAM" in
            "not set") ;;
            "") echo "Refusing to package: cannot tell who signed $(basename "$bundle")."; exit 1;;
            *) echo "Refusing to package: $(basename "$bundle") is signed with team $TEAM."; exit 1;;
        esac
    else
        case "$SIGNATURE" in
            *"code object is not signed at all"*) ;;
            *) echo "Refusing to package: cannot tell whether $(basename "$bundle") is signed: $SIGNATURE"; exit 1;;
        esac
    fi
done

# An .ipa is a zip with Payload/.
rm -rf build/Payload "$OUT"
mkdir build/Payload
cp -R "$APP" build/Payload/
( cd build && zip -qry "$OUT" Payload )
rm -rf build/Payload
echo "Unsigned build: $OUT"
echo "Sideload it, open it with JIT enabled by your sideloader (or a tool like StikDebug),"
echo "then add your application in the app and start it."
