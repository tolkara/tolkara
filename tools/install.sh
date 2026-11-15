#!/bin/bash
# Build the Tolkara app with your own signing team and install it on your iPad.
# usage: tools/install.sh            (settings from local.env; see local.env.example)
# Installing replaces the app under the same bundle ID and keeps its data.
# TOLKARA_MODE=local-signing also builds a Local signing page container for
# each executable in GUEST_EXE, signed with your developer identity, and copies
# it into the app's Documents/LocalSigning as <SHA-256 of the executable>.dylib.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
. tools/localenv.sh; tolkara_load_env
[ -n "${DEVELOPMENT_TEAM:-}" ] || { echo "Set DEVELOPMENT_TEAM in local.env (see local.env.example)."; exit 2; }
[ -n "${DEVICE:-}" ] || { echo "Set DEVICE=<iPad UDID> in local.env (xcrun devicectl list devices)."; exit 2; }
# A generic build is analysed against no executable at all.
SHIMS=${NATIVE_GUEST_SHIMS:-YES}
GUEST_EXE=${GUEST_EXE:-}
[ "$SHIMS" = GENERIC ] || [ -n "$GUEST_EXE" ] || { echo "Set GUEST_EXE to the macOS executable you own (several: separate with ':'), or NATIVE_GUEST_SHIMS=GENERIC to build for none. It is analysed, never bundled or modified."; exit 2; }
IFS=: read -r -a EXES <<< "$GUEST_EXE"
for exe in ${EXES[@]+"${EXES[@]}"}; do [ -f "$exe" ] || { echo "GUEST_EXE entry not found: $exe"; exit 2; }; done
case "${TOLKARA_MODE:-}" in
    ""|developer-service|local-signing) ;;
    *) echo "TOLKARA_MODE must be empty, developer-service or local-signing (see local.env.example)."; exit 2;;
esac
# One TOLKARA_CAPTURE entry per executable, in GUEST_EXE's order (see local.env.example).
CAPTURES=()
[ -n "${TOLKARA_CAPTURE:-}" ] && IFS=: read -r -a CAPTURES <<< "$TOLKARA_CAPTURE"
if [ "${TOLKARA_MODE:-}" = local-signing ] && [ ${#CAPTURES[@]} -gt ${#EXES[@]} ]; then
    echo "TOLKARA_CAPTURE has more entries than GUEST_EXE (one per executable, separated by ':')."; exit 2
fi
BUNDLE=${TOLKARA_BUNDLE_ID:-local.tolkara.app}
mkdir -p logs; LOG=logs/install-$(date +%Y%m%d-%H%M%S).log
tools/generate.sh
# NATIVE_GUEST_SHIMS=YES builds and signs only Tolkara's translation libraries
# for the API surface those executables import. They stay outside the app.
# GENERIC builds one adapter per framework instead, for no executable.
xcodebuild -project Tolkara.xcodeproj -scheme Tolkara -destination "platform=iOS,id=$DEVICE" \
    -derivedDataPath build/device -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    GUEST_EXE="$GUEST_EXE" NATIVE_GUEST_SHIMS="$SHIMS" TOLKARA_PROFILE="${TOLKARA_PROFILE:-}" TOLKARA_MODE="${TOLKARA_MODE:-}" \
    TOLKARA_SYSTEM_ROOTS="${TOLKARA_SYSTEM_ROOTS:-YES}" \
    build > "$LOG" 2>&1 \
    || { grep -E "error:" "$LOG" | head -20; echo "BUILD FAILED -> $LOG"; exit 1; }
xcrun devicectl device install app --device "$DEVICE" build/device/Build/Products/Debug-iphoneos/Tolkara.app
case "${TOLKARA_MODE:-}" in
local-signing)
    # Each container is a copy of one executable's final code pages, signed with
    # your developer identity. It stays on your Mac and your iPad.
    mkdir -p build/signed-image
    BUILT=()
    for i in "${!EXES[@]}"; do
        exe=${EXES[$i]}; capture=${CAPTURES[$i]:-}
        if [ "$capture" = skip ]; then echo "No page container for $(basename "$exe") (TOLKARA_CAPTURE entry 'skip')."; continue; fi
        CAPTURE=(); [ -n "$capture" ] && CAPTURE=(--capture "$capture")
        [ -n "$capture" ] || echo "Note: without a capture the page container for $(basename "$exe") only works if it does not rewrite its own code at launch."
        sha=$(shasum -a 256 "$exe" | cut -d' ' -f1)
        python3 tools/build_signed_container.py --guest "$exe" ${CAPTURE[@]+"${CAPTURE[@]}"} --platform ios \
            --team "$DEVELOPMENT_TEAM" --output "build/signed-image/$sha.dylib" \
            || { echo "PAGE CONTAINER BUILD FAILED for $(basename "$exe") (tools/build_signed_container.py)"; exit 1; }
        BUILT+=("$sha")
    done
    copy_containers() {
        for sha in ${BUILT[@]+"${BUILT[@]}"}; do
            xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
                --source "build/signed-image/$sha.dylib" --destination "Documents/LocalSigning/$sha.dylib" >> "$LOG" 2>&1 || return 1
        done
    }
    # A fresh install has no Documents/LocalSigning yet. If the copy cannot create
    # it, one launch in Local signing makes the folder; then copy again.
    if ! copy_containers; then
        echo "Launching Tolkara once in Local signing so it creates Documents/LocalSigning…"
        xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$BUNDLE" --execution-mode=local-signing >> "$LOG" 2>&1 \
            || { echo "APP LAUNCH FAILED (unlock the iPad; trust the developer in Settings if asked) -> $LOG"; exit 1; }
        sleep 3
        copy_containers || { echo "PAGE CONTAINER COPY FAILED -> $LOG"; exit 1; }
    fi
    echo "Installed with Local signing and ${#BUILT[@]} page container(s). Nothing to enrol. Next: copy your apps' files (see profiles/).";;
developer-service)
    echo "Installed with Developer service. Next: tools/enroll.sh (once), then copy your apps' files (see profiles/).";;
*)
    echo "Installed. The app asks for its execution mode on first launch: Developer service needs tools/enroll.sh (once);"
    echo "Local signing needs page containers (TOLKARA_MODE=local-signing builds and copies them). Then copy your apps' files (see profiles/).";;
esac
[ -z "${TOLKARA_MODE:-}" ] || echo "A mode already chosen in the app is kept; change it there with Execution mode…"
