#!/bin/bash
# Build the Windows-application runtime for arm64 macOS: Wine with the ARM64EC,
# aarch64 and i386 architectures, plus FEX's Windows-side emulator modules
# (libarm64ecfex.dll for x86-64 code, libwow64fex.dll for x86 code), assembled
# into build/windows-runtime/Wine. The same files run natively on an Apple
# silicon Mac (for validation, no Rosetta) and, once Tolkara hosts them, on the
# iPad. See docs/WINDOWS.md. Wine is LGPL, FEX is MIT; nothing here is part of
# any application.
#
# First version: the Wine tree and FEX build have not yet been exercised on a
# macOS host with arm64ec in this repository, so expect to iterate on the
# configure step. Each stage leaves a marker so a rerun resumes where it stopped.
#
# Variables (environment or local.env): WINE_REPO, WINE_BRANCH, FEX_REPO,
# FEX_BRANCH, LLVM_MINGW_VERSION, JOBS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ -f local.env ] && { . tools/localenv.sh; tolkara_load_env; }
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# bylaws/wine upstream-arm64ec is upstream Wine plus the ARM64EC/FEX series
# that Proton carries (FEX's own build instructions name it). Proton's tree
# itself (ValveSoftware/wine, experimental_11.0) is selectable with WINE_REPO
# and WINE_BRANCH, but it targets Linux: on macOS its fsync/ntsync, win32u
# OpenGL, winedmo and bcrypt changes do not compile, and none of them matter
# on an iPad.
WINE_REPO="${WINE_REPO:-https://github.com/bylaws/wine.git}"
WINE_BRANCH="${WINE_BRANCH:-upstream-arm64ec}"
FEX_REPO="${FEX_REPO:-https://github.com/FEX-Emu/FEX.git}"
FEX_BRANCH="${FEX_BRANCH:-main}"
LLVM_MINGW_VERSION="${LLVM_MINGW_VERSION:-20260922}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
OUT="$ROOT/build/windows-runtime"
SRC="$OUT/src"
MINGW="$OUT/llvm-mingw"
RUNTIME="$OUT/Wine"
mkdir -p "$OUT" "$SRC"

step() { printf '\n==> %s\n' "$*"; }
need_brew() {
    local missing=()
    for formula in "$@"; do brew list --formula "$formula" >/dev/null 2>&1 || missing+=("$formula"); done
    if [ ${#missing[@]} -gt 0 ]; then echo "error: install the build dependencies first: brew install ${missing[*]}"; exit 1; fi
}

step "Checking the host toolchain"
xcrun --sdk macosx --show-sdk-path >/dev/null || { echo "error: Xcode with the macOS SDK is required (DEVELOPER_DIR=$DEVELOPER_DIR)"; exit 1; }
need_brew bison pkgconf freetype gnutls cmake ninja autoconf
# macOS ships bison 2.3; Wine wants 3.0 or later.
export PATH="$(brew --prefix bison)/bin:$PATH"

step "LLVM mingw-w64 toolchain (PE compiler for the arm64ec, aarch64 and i386 Windows sides)"
if [ ! -x "$MINGW/bin/arm64ec-w64-mingw32-clang" ]; then
    TARBALL="llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal.tar.xz"
    if [ ! -f "$OUT/$TARBALL" ]; then
        curl -L --fail -o "$OUT/$TARBALL" "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION/$TARBALL"
    fi
    rm -rf "$MINGW"; mkdir -p "$MINGW"
    tar -xJf "$OUT/$TARBALL" -C "$MINGW" --strip-components=1
fi
"$MINGW/bin/arm64ec-w64-mingw32-clang" --version | head -1

step "Sources"
# The tree remembers where it was cloned from (local branches on top of it,
# such as the Tolkara fork branch, are fine). Another source: keep the old tree
# aside and start clean.
WINE_SOURCE_MARK="$SRC/wine.source"
if [ -e "$SRC/wine/.git" ] && [ -f "$WINE_SOURCE_MARK" ] && [ "$(cat "$WINE_SOURCE_MARK")" != "$WINE_REPO $WINE_BRANCH" ]; then
    mv "$SRC/wine" "$SRC/wine-$(date +%Y%m%d-%H%M%S)"; rm -f "$WINE_SOURCE_MARK"; rm -rf "$OUT/wine-build"
fi
if [ ! -e "$SRC/wine/.git" ]; then git clone --depth 1 --branch "$WINE_BRANCH" "$WINE_REPO" "$SRC/wine"; rm -rf "$OUT/wine-build"; fi
[ -f "$WINE_SOURCE_MARK" ] || printf '%s %s\n' "$WINE_REPO" "$WINE_BRANCH" > "$WINE_SOURCE_MARK"
if [ ! -e "$SRC/FEX/.git" ]; then git clone --depth 1 --recurse-submodules --shallow-submodules --branch "$FEX_BRANCH" "$FEX_REPO" "$SRC/FEX"; fi
(cd "$SRC/wine" && git log -1 --format='wine %h %s')
(cd "$SRC/FEX" && git log -1 --format='FEX %h %s')

step "FEX Windows-side emulator modules"
build_fex() {  # triple, output name
    local triple=$1 name=$2 dir="$OUT/fex-$1" built
    if [ -f "$OUT/$name" ]; then echo "$name already built"; return; fi
    # The FEX toolchain file finds <triple>-clang in PATH; put llvm-mingw first
    # for this step only (its ar/ranlib would otherwise shadow the host's).
    # FEX_TEB_TSD_OFFSET: the TEB lives in a pthread TSD slot on this host, as
    # Wine's -D__WINE_TEB_TSD_OFFSET says (docs/WINDOWS.md, "x18").
    # FEX_GUEST_ADDRESS_WINDOW: a 32-bit guest's address space sits at a 4 GB
    # window instead of at identity (docs/WINDOWS.md, "The 32-bit window").
    # 64 KiB sections, as Wine's own modules have: on 16 KiB host pages code
    # and writable data then never share a page, which an iPad's code pool
    # needs (docs/WINDOWS.md, "Executable memory on the iPad").
    PATH="$MINGW/bin:$PATH" cmake -G Ninja -S "$SRC/FEX" -B "$dir" \
        -DCMAKE_TOOLCHAIN_FILE="$SRC/FEX/Data/CMake/toolchain_mingw.cmake" -DMINGW_TRIPLE="$triple" \
        -DCMAKE_BUILD_TYPE=Release -DENABLE_LTO=False -DENABLE_JEMALLOC_GLIBC_ALLOC=False -DBUILD_TESTING=False -DTUNE_CPU=none \
        -DFEX_TEB_TSD_OFFSET=0x17f8 -DFEX_GUEST_ADDRESS_WINDOW=ON \
        -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--section-alignment=0x10000"
    PATH="$MINGW/bin:$PATH" cmake --build "$dir" -j "$JOBS"
    built="$(find "$dir" -name "$name" -type f | head -1)"
    [ -n "$built" ] || { echo "error: $name not produced; see $dir"; exit 1; }
    cp "$built" "$OUT/$name"
}
build_fex arm64ec-w64-mingw32 libarm64ecfex.dll
build_fex aarch64-w64-mingw32 libwow64fex.dll

step "Wine for arm64 macOS (arm64ec, aarch64 and i386 Windows sides)"
WINE_BUILD="$OUT/wine-build"; mkdir -p "$WINE_BUILD"
# Proton's tree carries configure.ac only and no generated Vulkan headers;
# upstream tarballs ship both. Generate them as Proton's own build does.
[ -x "$SRC/wine/configure" ] || (cd "$SRC/wine" && autoreconf -f 2>&1 | tail -3)
[ -f "$SRC/wine/include/wine/vulkan.h" ] || (cd "$SRC/wine/dlls/winevulkan" && python3 make_vulkan)
[ -f "$SRC/wine/include/wine/server_protocol.h" ] || (cd "$SRC/wine" && tools/make_requests)
[ -f "$SRC/wine/dlls/ntdll/ntsyscalls.h" ] || (cd "$SRC/wine" && tools/make_specfiles)
# winebuild and the PE link steps find lld-link, llvm-ar and friends by name:
# llvm-mingw's bin goes at the END of PATH so the host toolchain stays first.
export PATH="$PATH:$MINGW/bin"
# Libraries the Unix side opens by name at run time rather than linking:
# FreeType (fonts) and GnuTLS (TLS, schannel, crypt32). Configure records the
# name it dlopens; an @rpath name makes that the copy bundled beside the
# runtime (below) instead of whatever the host's search path holds.
DLOPENED="gnutls freetype"
soname() { basename "$(otool -D "$(brew --prefix "$1")/lib/lib$1.dylib" | tail -1)"; }
SONAMES=(); for lib in $DLOPENED; do SONAMES+=("ac_cv_lib_soname_$lib=@rpath/$(soname "$lib")"); done
if [ ! -f "$WINE_BUILD/.configured" ] || ! grep -q '@rpath/libgnutls' "$WINE_BUILD/include/config.h" 2>/dev/null; then
    MACSDK="$(xcrun --sdk macosx --show-sdk-path)"
    # Wine's configure builds the Unix side with the host clang and every PE
    # side with the mingw clang it is pointed at. No X11, ALSA or PulseAudio on
    # macOS; CoreAudio and the Mac driver are detected. Vulkan (MoltenVK) and
    # GStreamer are left to autodetection for now.
    (cd "$WINE_BUILD" && CC="xcrun clang" CXX="xcrun clang++" \
        CFLAGS="-isysroot $MACSDK -mmacosx-version-min=14.0" LDFLAGS="-isysroot $MACSDK" \
        "$SRC/wine/configure" --prefix="$RUNTIME" --enable-archs=arm64ec,aarch64,i386 \
        --with-mingw="$MINGW/bin/clang" --disable-tests --without-x --without-alsa --without-pulse --without-oss \
        enable_amd_ags_x64=no enable_winegstreamer=no "${SONAMES[@]}" \
        2>&1 | tee "$OUT/wine-configure.log")
    rm -f "$WINE_BUILD/.built"
    touch "$WINE_BUILD/.configured"
fi
if [ ! -f "$WINE_BUILD/.built" ]; then
    (cd "$WINE_BUILD" && make -j "$JOBS" 2>&1 | tee "$OUT/wine-build.log" | grep -E '^(make|.*error)' || true)
    [ -x "$WINE_BUILD/loader/wine" ] || { echo "error: Wine did not build; see $OUT/wine-build.log"; exit 1; }
    touch "$WINE_BUILD/.built"
fi
rm -rf "$RUNTIME"
(cd "$WINE_BUILD" && make install >"$OUT/wine-install.log" 2>&1)
# The emulator modules go where Wine looks for aarch64 PE builtins.
cp "$OUT/libarm64ecfex.dll" "$OUT/libwow64fex.dll" "$RUNTIME/lib/wine/aarch64-windows/"
# PE modules carry their DWARF inside the loaded image, and on the iPad all
# native code is loaded into prepared memory: install them without it. The
# build trees keep it for symbolizing.
find "$RUNTIME/lib/wine" -path '*-windows/*' -type f ! -name '*.a' -exec "$MINGW/bin/llvm-strip" --strip-debug {} +
# The runtime must be self-contained on the iPad: Homebrew libraries the Unix
# side links are copied beside it and their install names rewritten.
step "Bundling Homebrew libraries the Unix side links"
mkdir -p "$RUNTIME/lib"
bundle() {  # binary
    { otool -L "$1" | awk 'NR>1{print $1}' | grep -E "^$(brew --prefix)/" || true; } | while read -r lib; do
        local name; name="$(basename "$lib")"
        [ -f "$RUNTIME/lib/$name" ] || { cp "$lib" "$RUNTIME/lib/$name"; chmod u+w "$RUNTIME/lib/$name"; bundle "$RUNTIME/lib/$name"; }
        install_name_tool -change "$lib" "@rpath/$name" "$1" 2>/dev/null || true
    done
}
for lib in $DLOPENED; do
    name="$(soname "$lib")"
    cp "$(brew --prefix "$lib")/lib/$name" "$RUNTIME/lib/$name"; chmod u+w "$RUNTIME/lib/$name"
    install_name_tool -id "@rpath/$name" "$RUNTIME/lib/$name" 2>/dev/null || true
done
for binary in "$RUNTIME"/bin/* "$RUNTIME"/lib/wine/aarch64-unix/*.so "$RUNTIME"/lib/*.dylib; do
    # Links (bin/msiexec -> wine) name a binary handled under its own name.
    [ -f "$binary" ] && [ ! -L "$binary" ] && file "$binary" | grep -q Mach-O || continue
    bundle "$binary"
    # One run path to the bundled libraries, relative to this binary: the
    # Unix-side libraries have header room for only one more.
    rel="$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$RUNTIME/lib" "$(dirname "$binary")")"
    install_name_tool -add_rpath "@loader_path/$rel" "$binary"
done
# make install strips the Unix-side binaries, which invalidates their ad-hoc
# signatures on arm64: sign every Mach-O in the runtime again.
find "$RUNTIME" -type f | while read -r f; do
    file -b "$f" | grep -q '^Mach-O' && codesign -f -s - "$f" >/dev/null 2>&1 || true
done
step "Runtime assembled in $RUNTIME"
file "$RUNTIME/bin/wine"
ls "$RUNTIME/lib/wine/"
du -sh "$RUNTIME"
echo "Next: python3 profiles/heroes3-hota/install.py --installer <your GOG setup .exe> --stage-only"
