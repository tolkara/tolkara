#!/bin/bash
# Tests of the adapters that need UIKit, run in the simulator: each is built
# with its adapter's sources and run by simctl spawn, without an app.
# SIMULATOR in local.env (or the environment) names the device; it is booted if needed.
set -euo pipefail
cd "$(dirname "$0")/.."
. tools/localenv.sh; tolkara_load_env
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
SIM=${SIMULATOR:-iPad Pro 13-inch (M5)}
SIM_ID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
found = [d for devices in json.load(sys.stdin)["devices"].values() for d in devices if name in (d["name"], d["udid"])]
found.sort(key=lambda d: d["state"] != "Booted")
print(found[0]["udid"] if found else "")' "$SIM")
[ -n "$SIM_ID" ] || { echo "no available simulator named $SIM (set SIMULATOR in local.env)"; exit 2; }
xcrun simctl bootstatus "$SIM_ID" -b > /dev/null
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
mkdir -p build/emulation
CC=(xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -isysroot "$SDK" -fobjc-arc -O1 -g
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations -Itranslation/AKSupport)
"${CC[@]}" -Itranslation/CoreGraphics translation/AKSupport/AKSupport.m translation/CoreGraphics/*.m translation/CoreGraphics/*.c \
    tests/test_displays.m $(cat translation/CoreGraphics/ldflags) -framework CoreGraphics -o build/emulation/test_displays
xcrun simctl spawn "$SIM_ID" "$PWD/build/emulation/test_displays"
"${CC[@]}" translation/AKSupport/AKSupport.m translation/CoreAudio/*.m tests/test_audio_hardware.m \
    $(cat translation/CoreAudio/ldflags) -framework CoreAudio -o build/emulation/test_audio_hardware
xcrun simctl spawn "$SIM_ID" "$PWD/build/emulation/test_audio_hardware"
"${CC[@]}" -Itranslation/AppKit translation/AKSupport/AKSupport.m translation/AppKit/*.m translation/AppKit/*.c tests/test_appkit_views.m \
    $(cat translation/AppKit/ldflags) -o build/emulation/test_appkit_views
xcrun simctl spawn "$SIM_ID" "$PWD/build/emulation/test_appkit_views"
