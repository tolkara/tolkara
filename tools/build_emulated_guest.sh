#!/bin/bash
# Build only our runtime into the app. Stage the original as a separate module.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The second argument (GUEST_EXE) may list several executables separated by
# ':', like PATH: the compatibility libraries then cover all of them.
OUT=$1; EXES=()
[ -n "${2:-}" ] && IFS=: read -r -a EXES <<< "$2"
mkdir -p "$ROOT/build"
if [ ${#EXES[@]} -eq 0 ]; then
    EXES=("$ROOT/build/TestGuest")
    # Classic dyld info keeps the opcode binds covered on the device; chained
    # fixups are covered by tools/test_emulation.sh.
    xcrun --sdk macosx clang -fobjc-arc -arch arm64 -O1 -mmacosx-version-min=14.0 -Wl,-no_fixup_chains -o "${EXES[0]}" \
      "$ROOT/testguest/main.m" -framework Cocoa -framework Metal -framework QuartzCore
fi
for exe in "${EXES[@]}"; do [ -f "$exe" ] || { echo "error: GUEST_EXE entry not found: $exe"; exit 1; }; done
# The first executable is staged for tools/run.sh development imports.
EXE=${EXES[0]}
mkdir -p "$OUT/Guest"
# Remove resources left by older builds, including the proprietary executable.
rm -f "$OUT/Guest/OriginalExecutable.bin" "$OUT/Guest/manifest.json"
# A library map left by a build for one executable would turn a generic build's stubs off.
# absent.json: libraries a generic build presents as unavailable (translation/<Leaf>/absent).
rm -f "$OUT/Guest/libraries.json" "$OUT/Guest/absent.json"
rm -rf "$OUT/Guest/Nibs"
# Adapters left by a build for other executables or other experimental adapters:
# every one would be signed into the app, and a generic build opens ak<Leaf>.dylib by name.
rm -f "$OUT/Frameworks"/ak*.dylib "$OUT/Frameworks/libAKSupport.dylib"
MODULE="$ROOT/build/guest-module"
rm -rf "$MODULE/Nibs"
python3 "$ROOT/tools/package_guest.py" "$EXE" "$MODULE"

# App profiles name known apps and their file layout under Documents; the
# launcher adds an app when its files are present. Data only. Every profile in
# profiles/ is included; TOLKARA_PROFILE adds (and takes precedence as) your own.
rm -rf "$OUT/Guest/profile.json" "$OUT/Guest/Profiles"
mkdir -p "$OUT/Guest/Profiles"
for PROFILE in "$ROOT"/profiles/*/profile.json; do
    [ -f "$PROFILE" ] || continue
    python3 "$ROOT/tools/check_profile.py" "$PROFILE"
    cp "$PROFILE" "$OUT/Guest/Profiles/$(basename "$(dirname "$PROFILE")").json"
done
if [ -z "${TOLKARA_PROFILE:-}" ] && [ -f "$ROOT/local.env" ]; then
    TOLKARA_PROFILE=$(cd "$ROOT" && . tools/localenv.sh && tolkara_load_env && printf '%s' "${TOLKARA_PROFILE:-}")
fi
if [ -n "${TOLKARA_PROFILE:-}" ]; then
    case "$TOLKARA_PROFILE" in /*) PROFILE="$TOLKARA_PROFILE";; *) PROFILE="$ROOT/$TOLKARA_PROFILE";; esac
    python3 "$ROOT/tools/check_profile.py" "$PROFILE"
    cp "$PROFILE" "$OUT/Guest/Profiles/0-local.json"
fi

# Build/sign only our compatibility libraries. The original is never patched.
# GENERIC: one adapter per translation/<Framework>/, no executable classified.
# TOLKARA_EXPERIMENTAL_ADAPTERS=<Leaf>[:<Leaf>...] adds the adapters marked
# experimental (translation/<Leaf>/experimental); none take part by default.
if [ "${NATIVE_GUEST_SHIMS:-NO}" = YES ] || [ "${NATIVE_GUEST_SHIMS:-NO}" = GENERIC ]; then
    if [ "${PLATFORM_NAME:-iphoneos}" = iphonesimulator ]; then P=iossim; else P=ios; fi
    W="$ROOT/build/native-$P"; mkdir -p "$W" "$OUT/Frameworks"
    if [ "$NATIVE_GUEST_SHIMS" = GENERIC ]; then
        python3 "$ROOT/tools/build_shims.py" "$P" generic "$OUT/Frameworks" "$OUT/Guest/absent.json"
    else
        # Libraries an application bundles (Contents/Frameworks) run as original
        # code beside it, so their imports need compatibility libraries too.
        python3 "$ROOT/tools/classify.py" --bundled "${EXES[@]}" --out "$W/SURFACE.md" --map "$W/map.json" --raw "$W/surface.json"
        python3 "$ROOT/tools/build_shims.py" "$P" "$W/surface.json" "$OUT/Frameworks"
        cp "$W/map.json" "$OUT/Guest/libraries.json"
    fi
    # The builder's own Mac's public root certificates. TOLKARA_SYSTEM_ROOTS=NO
    # leaves them out, as the published release build does: it is not built on
    # the user's Mac, and nothing exported from macOS is redistributed.
    rm -f "$OUT/CompatibilityRootCertificates.plist"
    if [ "${TOLKARA_SYSTEM_ROOTS:-YES}" != NO ]; then
        MACSDK=$(xcrun --sdk macosx --show-sdk-path)
        xcrun --sdk macosx clang -target arm64-apple-macos14.0 -isysroot "$MACSDK" \
          -fobjc-arc -Wno-deprecated-declarations -framework Foundation -framework Security \
          "$ROOT/tools/export_system_anchors.m" -o "$ROOT/build/export_system_anchors"
        "$ROOT/build/export_system_anchors" "$OUT/CompatibilityRootCertificates.plist"
    fi
    for exe in "${EXES[@]}"; do
        RESOURCES="$(dirname "$(dirname "$exe")")/Resources"
        [ -d "$RESOURCES" ] || continue
        mkdir -p "$MODULE/Nibs"
        for nib in "$RESOURCES"/*.nib; do
            # Shared nib directory: the first executable's version of a name wins.
            [ -f "$nib" ] && [ ! -e "$MODULE/Nibs/$(basename "$nib").json" ] || continue
            python3 "$ROOT/tools/inspect_nib.py" "$nib" --out "$MODULE/Nibs/$(basename "$nib").json"
        done
    done
    if [ -n "${TOLKARA_VULKAN_RUNTIME:-}" ]; then
        python3 "$ROOT/tools/embed_vulkan_runtime.py" "$TOLKARA_VULKAN_RUNTIME" "$P" \
            "$OUT/Frameworks" "$OUT/Guest/libraries.json"
    fi
    for f in "$OUT/Frameworks"/*.dylib; do codesign -f -s "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$f" 2>/dev/null; done
fi
