#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/emulation
CC=(xcrun clang -std=c11 -D_DARWIN_C_SOURCE -Wall -Wextra -Werror -O1 -g
    -fsanitize=address,undefined -fno-omit-frame-pointer -Iruntime)
"${CC[@]}" -Itranslation/AppKit translation/AppKit/TouchTrackpad.c tests/test_touch_trackpad.c -o build/emulation/test_touch_trackpad
build/emulation/test_touch_trackpad
"${CC[@]}" runtime/GuestWaitTrace.c tests/test_wait_trace.c -o build/emulation/test_wait_trace
build/emulation/test_wait_trace
"${CC[@]}" runtime/GuestMemory.c runtime/DarwinMemory.c runtime/MemoryProbe.c tests/test_memory.c -o build/emulation/test_memory
build/emulation/test_memory
"${CC[@]}" runtime/GuestMemory.c runtime/GuestSparseMemory.c tests/test_sparse_memory.c -o build/emulation/test_sparse_memory
build/emulation/test_sparse_memory
"${CC[@]}" runtime/GuestSparseMemory.c runtime/GuestMemoryInstruction.c runtime/SparseMemoryProbe.c runtime/SparseMemoryProbeProgram.S tests/MemoryInstructionReference.S tests/test_memory_instruction.c -o build/emulation/test_memory_instruction
build/emulation/test_memory_instruction
"${CC[@]}" runtime/GuestMemory.c runtime/GuestCPU.c runtime/GuestSparseMemory.c runtime/GuestMemoryInstruction.c runtime/GuestExclusive.c runtime/GuestSoftwareVM.c runtime/SparseMemoryProbeProgram.S tests/test_software_vm.c -o build/emulation/test_software_vm
# ASan enlarges pthread stacks. Also exercise the exact 64 KiB guest-worker limit.
"${CC[@]}" -fno-sanitize=address,undefined runtime/GuestMemory.c runtime/GuestCPU.c runtime/GuestSparseMemory.c runtime/GuestMemoryInstruction.c runtime/GuestExclusive.c runtime/GuestSoftwareVM.c runtime/SparseMemoryProbeProgram.S tests/test_software_vm.c -o build/emulation/test_software_vm_small_stack
build/emulation/test_software_vm_small_stack
build/emulation/test_software_vm
build/emulation/test_software_vm --small-blocks
"${CC[@]}" runtime/GuestMemory.c runtime/GuestCPU.c runtime/CPUProbe.c runtime/CPUProbeProgram.S tests/test_cpu.c -o build/emulation/test_cpu
build/emulation/test_cpu
"${CC[@]}" -Iauthorization authorization/LocalRoute.c tests/test_local_route.c -o build/emulation/test_local_route
build/emulation/test_local_route
"${CC[@]}" -Iauthorization authorization/DebugWire.c tests/test_debug_wire.c -o build/emulation/test_debug_wire
build/emulation/test_debug_wire
"${CC[@]}" -Iauthorization authorization/Control/ArenaControl.c tests/test_arena_control.c -o build/emulation/test_arena_control
build/emulation/test_arena_control
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address authorization/Pairing/PairingWire.swift \
    authorization/Debugger/DebugArenaRequest.swift tests/test_debug_request.swift \
    -o build/emulation/test_debug_request
build/emulation/test_debug_request
"${CC[@]}" -c authorization/DebugWire.c -o build/emulation/DebugWire.o
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address -import-objc-header authorization/Transport/TransportBridge.h \
    authorization/Pairing/PairingWire.swift authorization/Debugger/DebugArenaRequest.swift \
    authorization/Debugger/DebugProtocolWire.swift authorization/Debugger/DebugArenaSession.swift \
    build/emulation/DebugWire.o tools/probe_debug_arena.swift -o build/probe_debug_arena
python3 tests/test_debug_arena_peer.py
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address authorization/Pairing/*.swift tests/test_pairing.swift \
    -o build/emulation/test_pairing
build/emulation/test_pairing
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address authorization/Pairing/PairingWire.swift \
    authorization/Pairing/PairingIdentity.swift authorization/Storage/*.swift \
    tests/test_pairing_storage.swift -o build/emulation/test_pairing_storage
build/emulation/test_pairing_storage
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address authorization/Pairing/*.swift tests/PairingPeerFixture.swift \
    tests/test_pairing_session.swift -o build/emulation/test_pairing_session
build/emulation/test_pairing_session
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address authorization/Pairing/PairingWire.swift \
    authorization/Transport/CDTunnelWire.swift tests/test_cd_tunnel.swift \
    -o build/emulation/test_cd_tunnel
build/emulation/test_cd_tunnel
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address authorization/Pairing/PairingWire.swift \
    authorization/Transport/TunnelTCP.swift tests/test_tunnel_tcp.swift \
    -o build/emulation/test_tunnel_tcp
build/emulation/test_tunnel_tcp
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors -g -sanitize=address \
    authorization/Pairing/PairingWire.swift authorization/Transport/TunnelTCP.swift \
    authorization/Transport/LocalTCPIPv4.swift tests/test_local_tcp_ipv4.swift \
    -o build/emulation/test_local_tcp_ipv4
build/emulation/test_local_tcp_ipv4
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address authorization/Pairing/PairingWire.swift \
    authorization/Transport/TunnelTCP.swift tools/probe_tunnel_tcp.swift \
    -o build/probe_tunnel_tcp
python3 tests/test_tunnel_tcp_peer.py
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address authorization/Pairing/PairingWire.swift \
    authorization/Transport/RemoteXPCWire.swift tests/test_remote_xpc.swift \
    -o build/emulation/test_remote_xpc
build/emulation/test_remote_xpc
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address authorization/Pairing/PairingWire.swift \
    authorization/Transport/RemoteXPCWire.swift authorization/Transport/RemoteDiscovery.swift \
    tools/probe_remote_discovery.swift -o build/probe_remote_discovery
python3 tests/test_remote_discovery_peer.py
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address authorization/Pairing/PairingWire.swift \
    authorization/Transport/CDTunnelWire.swift authorization/Transport/TunnelTCP.swift \
    authorization/Transport/TunnelStreams.swift tests/test_tunnel_streams.swift \
    -o build/emulation/test_tunnel_streams
build/emulation/test_tunnel_streams
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Iauthorization/Pairing \
    -c authorization/Pairing/TunnelTLS.m -o build/emulation/TunnelTLS.o
for test in tunnel_manager developer_session; do
    xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
        -g -sanitize=address -import-objc-header authorization/Transport/TransportBridge.h \
        authorization/Pairing/*.swift authorization/Transport/*.swift \
        build/emulation/TunnelTLS.o "tests/test_${test}.swift" -o "build/emulation/test_${test}"
    "build/emulation/test_${test}"
done
"${CC[@]}" runtime/NativeCodeMemory.c tests/test_native_memory.c -o build/emulation/test_native_memory
build/emulation/test_native_memory
"${CC[@]}" runtime/HostDiagnostics.c runtime/HostExecutionProbe.c runtime/NativeCodeMemory.c tests/test_host_diagnostics.c -o build/emulation/test_host_diagnostics
build/emulation/test_host_diagnostics
"${CC[@]}" runtime/HostExecutionProbe.c runtime/NativeCodeMemory.c tests/test_arena_probe.c -o build/emulation/test_arena_probe
build/emulation/test_arena_probe
"${CC[@]}" runtime/DebuggerArena.c runtime/HostDiagnostics.c runtime/HostExecutionProbe.c runtime/NativeCodeMemory.c tests/test_debugger_arena.c -o build/emulation/test_debugger_arena
build/emulation/test_debugger_arena
"${CC[@]}" tests/test_native_policy.c -o build/emulation/test_native_policy
build/emulation/test_native_policy
"${CC[@]}" runtime/GuestMemory.c runtime/SignedImage.c tests/test_signed_image.c -o build/emulation/test_signed_image
build/emulation/test_signed_image
"${CC[@]}" -Ilauncher/App launcher/App/SignedFileProbe.c tests/test_signed_file_probe.c -o build/emulation/test_signed_file_probe
build/emulation/test_signed_file_probe
xcrun clang -fobjc-arc -Wall -Wextra -Werror -g -fsanitize=address,undefined \
    -Iruntime -Iauthorization -Iauthorization/App -framework Foundation \
    runtime/NativeCodeMemory.c authorization/Control/ArenaControl.c \
    authorization/App/LocalArenaPublisher.m tests/test_local_arena_publisher.m \
    -o build/emulation/test_local_arena_publisher
build/emulation/test_local_arena_publisher
xcrun clang -fobjc-arc -Wall -Wextra -Werror -g -fsanitize=address,undefined \
    -Iruntime -Iauthorization -Iauthorization/App -framework Foundation \
    authorization/Control/ArenaControl.c authorization/App/LocalArenaPoller.m tests/test_local_arena_poller.m \
    -o build/emulation/test_local_arena_poller
build/emulation/test_local_arena_poller
"${CC[@]}" runtime/GuestWait.c tests/test_guest_wait.c -o build/emulation/test_guest_wait
build/emulation/test_guest_wait
"${CC[@]}" runtime/GuestWait.c tests/test_guest_wait_runloop.c -framework CoreFoundation -o build/emulation/test_guest_wait_runloop
build/emulation/test_guest_wait_runloop
"${CC[@]}" runtime/GuestMemory.c runtime/GuestImage.c runtime/GuestLink.c tests/test_link.c -o build/emulation/test_link
build/emulation/test_link
"${CC[@]}" runtime/GuestPaths.c tests/test_paths.c -o build/emulation/test_paths
build/emulation/test_paths
"${CC[@]}" runtime/GuestVMBudget.c tests/test_vm_budget.c -o build/emulation/test_vm_budget
build/emulation/test_vm_budget
"${CC[@]}" runtime/GuestMemory.c runtime/GuestImage.c runtime/GuestFixups.c runtime/GuestLink.c tools/guest_probe.c -o build/emulation/guest_probe_sanitized
python3 tests/test_image.py build/emulation/guest_probe_sanitized
# An image with chained fixups: the probe walks the chains.
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 -x c -o build/emulation/chained_fixture - <<'C'
#include <stdio.h>
static const char *message = "hello";
const void *pointers[] = {&message, (const void *)&puts, &pointers[0]};
int main(void) { puts(message); return pointers[2] != 0; }
C
build/emulation/guest_probe_sanitized build/emulation/chained_fixture --validate-fixups > /dev/null
# Built for a current macOS, constructors are recorded as offsets.
cat > build/emulation/initializers.c <<'C'
static int ready;
__attribute__((constructor)) static void first(void) { ready = 1; }
__attribute__((constructor)) static void second(void) { ready = 2; }
int main(void) { return ready; }
C
cat > build/emulation/initialized_library.c <<'C'
static int loaded;
__attribute__((constructor)) static void load(void) { loaded = 1; }
int library_loaded(void) { return loaded; }
C
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 build/emulation/initializers.c \
    -o build/emulation/initializers
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 -dynamiclib \
    -install_name @rpath/libinitialized.dylib build/emulation/initialized_library.c \
    -o build/emulation/libinitialized.dylib
build/emulation/guest_probe_sanitized build/emulation/initializers > build/emulation/initializers.txt
build/emulation/guest_probe_sanitized build/emulation/libinitialized.dylib --library > build/emulation/initialized-library.txt
# What the section records, read without the loader.
read -r -a RECORDED <<<"$(otool -X -s __TEXT __init_offsets build/emulation/initializers | cut -f2)"
grep -q "initializers=2 first=$(printf '%#x' $((0x100000000 + 0x${RECORDED[0]}))) (offsets)" build/emulation/initializers.txt
grep -q "initializer 1=$(printf '%#x' $((0x100000000 + 0x${RECORDED[1]})))$" build/emulation/initializers.txt
grep -q "initializers=1 first=0x[0-9a-f]* (offsets)" build/emulation/initialized-library.txt
# An application carrying a library of its own, through @rpath.
rm -rf build/emulation/Fixture.app
mkdir -p build/emulation/Fixture.app/Contents/MacOS build/emulation/Fixture.app/Contents/Frameworks
cat > build/emulation/carried.c <<'C'
int carried_value(void) { return 7; }
C
cat > build/emulation/carrier.c <<'C'
int carried_value(void);
int main(void) { return carried_value(); }
C
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 -dynamiclib \
    -install_name @rpath/libcarried.dylib build/emulation/carried.c \
    -o build/emulation/Fixture.app/Contents/Frameworks/libcarried.dylib
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 build/emulation/carrier.c \
    build/emulation/Fixture.app/Contents/Frameworks/libcarried.dylib -Wl,-rpath,@executable_path/../Frameworks \
    -o build/emulation/Fixture.app/Contents/MacOS/Fixture
build/emulation/guest_probe_sanitized build/emulation/Fixture.app/Contents/MacOS/Fixture \
    --carried-libraries --validate-fixups > build/emulation/fixture.txt
grep -q "imports from carried libraries=1 elsewhere=0" build/emulation/fixture.txt
# Two carried libraries exporting one name; the ordinal decides.
rm -rf build/emulation/Ambiguous.app
mkdir -p build/emulation/Ambiguous.app/Contents/MacOS build/emulation/Ambiguous.app/Contents/Frameworks
cat > build/emulation/first.c <<'C'
int first_only(void) { return 1; }
C
cat > build/emulation/second.c <<'C'
int carried_shared(void) { return 2; }
C
cat > build/emulation/first_shared.c <<'C'
int first_only(void) { return 1; }
int carried_shared(void) { return 1; }
C
cat > build/emulation/ambiguous.c <<'C'
int first_only(void);
int carried_shared(void);
int main(void) { return first_only() + carried_shared(); }
C
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 -dynamiclib \
    -install_name @rpath/libfirst.dylib build/emulation/first.c \
    -o build/emulation/Ambiguous.app/Contents/Frameworks/libfirst.dylib
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 -dynamiclib \
    -install_name @rpath/libsecond.dylib build/emulation/second.c \
    -o build/emulation/Ambiguous.app/Contents/Frameworks/libsecond.dylib
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 build/emulation/ambiguous.c \
    build/emulation/Ambiguous.app/Contents/Frameworks/libfirst.dylib \
    build/emulation/Ambiguous.app/Contents/Frameworks/libsecond.dylib \
    -Wl,-rpath,@executable_path/../Frameworks -o build/emulation/Ambiguous.app/Contents/MacOS/Ambiguous
# The first library takes the shared name only after linking.
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 -dynamiclib \
    -install_name @rpath/libfirst.dylib build/emulation/first_shared.c \
    -o build/emulation/Ambiguous.app/Contents/Frameworks/libfirst.dylib
build/emulation/guest_probe_sanitized build/emulation/Ambiguous.app/Contents/MacOS/Ambiguous \
    --carried-libraries --validate-fixups > build/emulation/ambiguous-imports.txt
grep -q "_carried_shared <- @rpath/libsecond.dylib" build/emulation/ambiguous-imports.txt
# A carried library that later exports a system name does not take it.
rm -rf build/emulation/Shadow.app
mkdir -p build/emulation/Shadow.app/Contents/MacOS build/emulation/Shadow.app/Contents/Frameworks
cat > build/emulation/plain.c <<'C'
int plain_value(void) { return 1; }
C
cat > build/emulation/plain_system.c <<'C'
#include <stddef.h>
int plain_value(void) { return 1; }
size_t strlen(const char *text) { (void)text; return 0; }
C
cat > build/emulation/system_user.c <<'C'
#include <string.h>
int plain_value(void);
int main(int argc, char **argv) { (void)argc; return (int)strlen(argv[0]) + plain_value(); }
C
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 -dynamiclib \
    -install_name @rpath/libplain.dylib build/emulation/plain.c \
    -o build/emulation/Shadow.app/Contents/Frameworks/libplain.dylib
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 build/emulation/system_user.c \
    build/emulation/Shadow.app/Contents/Frameworks/libplain.dylib \
    -Wl,-rpath,@executable_path/../Frameworks -o build/emulation/Shadow.app/Contents/MacOS/Shadow
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 -fno-builtin -dynamiclib \
    -install_name @rpath/libplain.dylib build/emulation/plain_system.c \
    -o build/emulation/Shadow.app/Contents/Frameworks/libplain.dylib
build/emulation/guest_probe_sanitized build/emulation/Shadow.app/Contents/MacOS/Shadow \
    --carried-libraries --validate-fixups > build/emulation/shadow-imports.txt
grep -q "_plain_value <- @rpath/libplain.dylib" build/emulation/shadow-imports.txt
if grep -q "_strlen <- " build/emulation/shadow-imports.txt; then echo "a carried library took a system import"; exit 1; fi
# The probe's imports for one image, which end with its "[fixups] <name>" line.
group_of() { awk -v end="[fixups] $2" 'index($0, end) == 1 { printf "%s", buffer; exit }
    /^\[fixups\] / { buffer = ""; next } { buffer = buffer $0 "\n" }' "$1"; }
# C++ weak definitions coalesce to the executable, as dyld's load order has it,
# for the executable's own binds and for a carried library's.
rm -rf build/emulation/Coalesce.app
mkdir -p build/emulation/Coalesce.app/Contents/MacOS build/emulation/Coalesce.app/Contents/Frameworks
cat > build/emulation/counter.h <<'C'
#include <cstdlib>
inline int &counter() { static int c = std::rand(); return c; }
C
cat > build/emulation/coalesce_lib.cpp <<'C'
#include "counter.h"
int library_counter() { return counter(); }
C
cat > build/emulation/coalesce.cpp <<'C'
#include "counter.h"
int library_counter();
int main() { return counter() + library_counter(); }
C
xcrun --sdk macosx clang++ -arch arm64 -mmacosx-version-min=12.0 -dynamiclib \
    -install_name @rpath/libcoalesce.dylib build/emulation/coalesce_lib.cpp \
    -o build/emulation/Coalesce.app/Contents/Frameworks/libcoalesce.dylib
xcrun --sdk macosx clang++ -arch arm64 -mmacosx-version-min=12.0 build/emulation/coalesce.cpp \
    build/emulation/Coalesce.app/Contents/Frameworks/libcoalesce.dylib \
    -Wl,-rpath,@executable_path/../Frameworks -o build/emulation/Coalesce.app/Contents/MacOS/Coalesce
build/emulation/guest_probe_sanitized build/emulation/Coalesce.app/Contents/MacOS/Coalesce \
    --carried-libraries --validate-fixups > build/emulation/coalesce-imports.txt
group_of build/emulation/coalesce-imports.txt @rpath/libcoalesce.dylib > build/emulation/coalesce-library.txt
group_of build/emulation/coalesce-imports.txt validated > build/emulation/coalesce-executable.txt
for group in library executable; do
    for symbol in __Z7counterv __ZGVZ7countervE1c __ZZ7countervE1c; do
        grep -q "^\[import\] $symbol <- <executable>$" build/emulation/coalesce-$group.txt
    done
done
grep -q "^\[import\] __Z15library_counterv <- @rpath/libcoalesce.dylib$" build/emulation/coalesce-executable.txt
grep -q "from the executable itself=6" build/emulation/coalesce-imports.txt
# A library binding to itself, and a flat lookup, answered inside the application.
rm -rf build/emulation/Ordinals.app
mkdir -p build/emulation/Ordinals.app/Contents/MacOS build/emulation/Ordinals.app/Contents/Frameworks
cat > build/emulation/provider.c <<'C'
int provider_value(void) { return 2; }
C
cat > build/emulation/flat.c <<'C'
int provider_value(void);
int flat_value(void) { return provider_value(); }
C
cat > build/emulation/self.c <<'C'
int self_value(void) { return 3; }
int self_caller(void) { return self_value(); }
C
cat > build/emulation/ordinals.c <<'C'
int flat_value(void); int self_caller(void); int provider_value(void);
int main(void) { return flat_value() + self_caller() + provider_value(); }
C
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 -dynamiclib \
    -install_name @rpath/libprovider.dylib build/emulation/provider.c \
    -o build/emulation/Ordinals.app/Contents/Frameworks/libprovider.dylib
# Its one import is left to a flat lookup at load time.
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 -dynamiclib -Wl,-undefined,dynamic_lookup \
    -install_name @rpath/libflat.dylib build/emulation/flat.c \
    -o build/emulation/Ordinals.app/Contents/Frameworks/libflat.dylib 2>/dev/null
# Interposable: its own call goes through a bind to itself.
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 -dynamiclib -Wl,-interposable \
    -install_name @rpath/libself.dylib build/emulation/self.c \
    -o build/emulation/Ordinals.app/Contents/Frameworks/libself.dylib
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 build/emulation/ordinals.c \
    build/emulation/Ordinals.app/Contents/Frameworks/libprovider.dylib \
    build/emulation/Ordinals.app/Contents/Frameworks/libflat.dylib \
    build/emulation/Ordinals.app/Contents/Frameworks/libself.dylib \
    -Wl,-rpath,@executable_path/../Frameworks -o build/emulation/Ordinals.app/Contents/MacOS/Ordinals
build/emulation/guest_probe_sanitized build/emulation/Ordinals.app/Contents/MacOS/Ordinals \
    --carried-libraries --validate-fixups > build/emulation/ordinals-imports.txt
group_of build/emulation/ordinals-imports.txt @rpath/libflat.dylib > build/emulation/ordinals-flat.txt
group_of build/emulation/ordinals-imports.txt @rpath/libself.dylib > build/emulation/ordinals-self.txt
grep -q "^\[import\] _provider_value <- @rpath/libprovider.dylib$" build/emulation/ordinals-flat.txt
grep -q "^\[import\] _self_value <- @rpath/libself.dylib$" build/emulation/ordinals-self.txt
# The executable's own thread-local weak definitions bind to its TLV descriptors.
cat > build/emulation/tlv.cpp <<'C'
inline int &slot() { static thread_local int value = 7; return value; }
int main() { return slot(); }
C
xcrun --sdk macosx clang++ -arch arm64 -mmacosx-version-min=12.0 build/emulation/tlv.cpp -o build/emulation/tlv
build/emulation/guest_probe_sanitized build/emulation/tlv --validate-fixups > build/emulation/tlv-imports.txt
grep -q "^\[import\] __ZZ4slotvE5value <- <executable>$" build/emulation/tlv-imports.txt
DESCRIPTOR=$(xcrun dyld_info -exports build/emulation/tlv | awk '$2 == "__ZZ4slotvE5value" { print $1 }')
build/emulation/guest_probe_sanitized build/emulation/tlv --export __ZZ4slotvE5value > build/emulation/tlv-export.txt
grep -q "__ZZ4slotvE5value=$(printf '%#x' $((0x100000000 + DESCRIPTOR))) absolute=0 weak per-thread$" build/emulation/tlv-export.txt
# A strong definition in a carried library wins over the executable's weak one.
rm -rf build/emulation/Strong.app
mkdir -p build/emulation/Strong.app/Contents/MacOS build/emulation/Strong.app/Contents/Frameworks
cat > build/emulation/strong_lib.c <<'C'
__attribute__((weak)) int library_dummy(void) { return 0; }
int shared_value(void) { return 2; }
C
cat > build/emulation/strong_main.c <<'C'
int library_dummy(void);
__attribute__((weak)) int shared_value(void) { return 1; }
int main(void) { return shared_value() + library_dummy(); }
C
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 -dynamiclib \
    -install_name @rpath/libstrong.dylib build/emulation/strong_lib.c \
    -o build/emulation/Strong.app/Contents/Frameworks/libstrong.dylib
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 build/emulation/strong_main.c \
    build/emulation/Strong.app/Contents/Frameworks/libstrong.dylib \
    -Wl,-rpath,@executable_path/../Frameworks -o build/emulation/Strong.app/Contents/MacOS/Strong
build/emulation/guest_probe_sanitized build/emulation/Strong.app/Contents/MacOS/Strong \
    --carried-libraries --validate-fixups > build/emulation/strong-imports.txt
grep -q "^\[import\] _shared_value <- @rpath/libstrong.dylib$" build/emulation/strong-imports.txt
# A library that re-exports another answers for its names.
rm -rf build/emulation/Reexport.app
mkdir -p build/emulation/Reexport.app/Contents/MacOS build/emulation/Reexport.app/Contents/Frameworks
cat > build/emulation/defines.c <<'C'
int real_name(void) { return 3; }
int other_name(void) { return 4; }
C
cat > build/emulation/subset.c <<'C'
int subset_only(void) { return 1; }
C
cat > build/emulation/facade.c <<'C'
int facade_only(void) { return 1; }
C
cat > build/emulation/shadow.c <<'C'
int shadow_only(void) { return 1; }
C
cat > build/emulation/shadow_shared.c <<'C'
int shadow_only(void) { return 1; }
int real_name(void) { return 9; }
int other_name(void) { return 9; }
C
cat > build/emulation/reexport.c <<'C'
int shadow_only(void); int real_name(void); int other_name(void);
int main(void) { return shadow_only() + real_name() + other_name(); }
C
printf '_real_name\n' > build/emulation/reexported-symbols.txt
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 -dynamiclib \
    -install_name @rpath/libdefines.dylib build/emulation/defines.c \
    -o build/emulation/Reexport.app/Contents/Frameworks/libdefines.dylib
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 -dynamiclib \
    -install_name @rpath/libsubset.dylib build/emulation/subset.c \
    build/emulation/Reexport.app/Contents/Frameworks/libdefines.dylib \
    -Wl,-reexported_symbols_list,build/emulation/reexported-symbols.txt \
    -Wl,-rpath,@loader_path/../Frameworks \
    -o build/emulation/Reexport.app/Contents/Frameworks/libsubset.dylib
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 -dynamiclib \
    -install_name @rpath/libfacade.dylib build/emulation/facade.c \
    -Wl,-reexport_library,build/emulation/Reexport.app/Contents/Frameworks/libdefines.dylib \
    -Wl,-rpath,@loader_path/../Frameworks \
    -o build/emulation/Reexport.app/Contents/Frameworks/libfacade.dylib
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 -dynamiclib \
    -install_name @rpath/libshadow.dylib build/emulation/shadow.c \
    -o build/emulation/Reexport.app/Contents/Frameworks/libshadow.dylib
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 build/emulation/reexport.c \
    build/emulation/Reexport.app/Contents/Frameworks/libshadow.dylib \
    build/emulation/Reexport.app/Contents/Frameworks/libsubset.dylib \
    build/emulation/Reexport.app/Contents/Frameworks/libfacade.dylib \
    -Lbuild/emulation/Reexport.app/Contents/Frameworks -Wl,-rpath,@executable_path/../Frameworks \
    -o build/emulation/Reexport.app/Contents/MacOS/Reexport
# The shadowing library takes the names only after linking.
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 -dynamiclib \
    -install_name @rpath/libshadow.dylib build/emulation/shadow_shared.c \
    -o build/emulation/Reexport.app/Contents/Frameworks/libshadow.dylib
build/emulation/guest_probe_sanitized build/emulation/Reexport.app/Contents/MacOS/Reexport \
    --carried-libraries --validate-fixups > build/emulation/reexport-imports.txt
grep -q "_real_name <- @rpath/libdefines.dylib" build/emulation/reexport-imports.txt
grep -q "_other_name <- @rpath/libdefines.dylib" build/emulation/reexport-imports.txt
# A carried library with no rpath of its own.
rm -rf build/emulation/Chain.app
mkdir -p build/emulation/Chain.app/Contents/MacOS build/emulation/Chain.app/Contents/Frameworks
cat > build/emulation/inner.c <<'C'
int inner_value(void) { return 5; }
C
cat > build/emulation/outer.c <<'C'
int inner_value(void);
int outer_value(void) { return inner_value(); }
C
cat > build/emulation/chain.c <<'C'
int outer_value(void);
int main(void) { return outer_value(); }
C
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 -dynamiclib \
    -install_name @rpath/libinner.dylib build/emulation/inner.c \
    -o build/emulation/Chain.app/Contents/Frameworks/libinner.dylib
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 -dynamiclib \
    -install_name @rpath/libouter.dylib build/emulation/outer.c \
    build/emulation/Chain.app/Contents/Frameworks/libinner.dylib \
    -o build/emulation/Chain.app/Contents/Frameworks/libouter.dylib
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 build/emulation/chain.c \
    build/emulation/Chain.app/Contents/Frameworks/libouter.dylib \
    -Lbuild/emulation/Chain.app/Contents/Frameworks -Wl,-rpath,@executable_path/../Frameworks \
    -o build/emulation/Chain.app/Contents/MacOS/Chain
build/emulation/guest_probe_sanitized build/emulation/Chain.app/Contents/MacOS/Chain \
    --carried-libraries --validate-fixups > build/emulation/chain-imports.txt
grep -q "carries 2 libraries of its own, 0 refused" build/emulation/chain-imports.txt
grep -q "_inner_value <- @rpath/libinner.dylib" build/emulation/chain-imports.txt
# A carried library with thread-local constructors is refused, not bound.
rm -rf build/emulation/Constructors.app
mkdir -p build/emulation/Constructors.app/Contents/MacOS build/emulation/Constructors.app/Contents/Frameworks
cat > build/emulation/tlsinit.c <<'C'
int constructed_value(void) { return 3; }
static void constructor(void) {}
__asm__(".section __DATA,__thread_init\n.p2align 3\n.quad _constructor\n");
void *keep_constructor(void) { return (void *)constructor; }
C
cat > build/emulation/constructed.c <<'C'
int constructed_value(void);
int main(void) { return constructed_value(); }
C
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 -dynamiclib \
    -install_name @rpath/libtlsinit.dylib build/emulation/tlsinit.c \
    -o build/emulation/Constructors.app/Contents/Frameworks/libtlsinit.dylib
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=12.0 build/emulation/constructed.c \
    build/emulation/Constructors.app/Contents/Frameworks/libtlsinit.dylib \
    -Wl,-rpath,@executable_path/../Frameworks -o build/emulation/Constructors.app/Contents/MacOS/Constructors
# The linker writes it as regular; give dyld's type.
python3 - build/emulation/Constructors.app/Contents/Frameworks/libtlsinit.dylib <<'PY'
import struct, sys
data = bytearray(open(sys.argv[1], 'rb').read())
at = data.find(b'__thread_init\0\0\0__DATA\0')
assert at > 0
struct.pack_into('<I', data, at + 64, 0x15)  # S_THREAD_LOCAL_INIT_FUNCTION_POINTERS
open(sys.argv[1], 'wb').write(data)
PY
build/emulation/guest_probe_sanitized build/emulation/Constructors.app/Contents/MacOS/Constructors \
    --carried-libraries --validate-fixups > build/emulation/constructors-imports.txt
grep -q "carries 0 libraries of its own, 1 refused" build/emulation/constructors-imports.txt
grep -q "@rpath/libtlsinit.dylib needs thread-local constructors" build/emulation/constructors-imports.txt
grep -q "imports from carried libraries=0 elsewhere=1" build/emulation/constructors-imports.txt
python3 tests/test_package.py
python3 tests/test_profile.py
xcrun clang -arch arm64 -x c -o build/emulation/module_fixture - <<'C'
int main(void) { return 42; }
C
xcrun clang -fobjc-arc -Wno-deprecated-declarations -Wall -Wextra -Werror \
    -O1 -g -fsanitize=address,undefined -Iruntime -framework Foundation \
    runtime/GuestModule.m runtime/GuestMemory.c runtime/GuestImage.c tests/test_guest_module.m \
    -o build/emulation/test_guest_module
build/emulation/test_guest_module build/emulation/module_fixture
for auth in 0 1; do   # TolkaraDiagnostics and Tolkara (TOLKARA_INTEGRATED_AUTH)
    xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
        -DTOLKARA_INTEGRATED_AUTH=$auth -Ilauncher/App -framework Foundation \
        launcher/App/ExecutionMode.m tests/test_execution_mode.m -o "build/emulation/test_execution_mode_$auth"
    "build/emulation/test_execution_mode_$auth"
done
xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -Ilauncher/App -framework Foundation \
    launcher/App/StartupActivityText.m tests/test_startup_activity.m -o build/emulation/test_startup_activity
build/emulation/test_startup_activity
xcrun clang -fobjc-arc -Wno-deprecated-declarations -Wall -Wextra -Werror \
    -O1 -g -fsanitize=address,undefined -Iruntime -Ilauncher/App -framework Foundation \
    launcher/App/AppLibrary.m runtime/GuestModule.m runtime/GuestMemory.c runtime/GuestImage.c tests/test_app_library.m \
    -o build/emulation/test_app_library
build/emulation/test_app_library build/emulation/module_fixture
xcrun clang -fobjc-arc -Wall -Wextra -Werror \
    -O1 -g -fsanitize=address,undefined -Iruntime -framework Foundation \
    runtime/GuestStubs.m runtime/GuestStubsArm64.S tests/test_guest_stubs.m \
    -o build/emulation/test_guest_stubs
build/emulation/test_guest_stubs
xcrun clang -std=c11 -Wall -Wextra -Werror \
    -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -Iruntime \
    runtime/GuestWrap.c runtime/GuestWrapArm64.S tests/test_guest_wrap.c \
    -o build/emulation/test_guest_wrap
build/emulation/test_guest_wrap
xcrun clang -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -Iruntime -c runtime/GuestWrap.c -o build/emulation/wrap_exception.o
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -Iruntime runtime/GuestWrapArm64.S tests/test_guest_wrap_exception.cpp \
    build/emulation/wrap_exception.o -o build/emulation/test_guest_wrap_exception
build/emulation/test_guest_wrap_exception
xcrun clang++ -std=c++17 -O1 -g -Wall -Wextra -Werror -dynamiclib \
    tests/unwind_fixture.cpp tests/unwind_fixture_arm64.S -o build/emulation/unwind_fixture.dylib
for source in GuestUnwind GuestMemory GuestImage GuestFixups GuestWrap; do
    xcrun clang -std=c11 -D_DARWIN_C_SOURCE -O1 -g -Wall -Wextra -Werror \
        -fsanitize=address,undefined -Iruntime -c "runtime/$source.c" \
        -o "build/emulation/unwind_$source.o"
done
xcrun clang++ -std=c++17 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
    -Iruntime tests/test_guest_unwind.cpp runtime/GuestWrapArm64.S \
    build/emulation/unwind_Guest{Unwind,Memory,Image,Fixups,Wrap}.o -o build/emulation/test_guest_unwind
build/emulation/test_guest_unwind build/emulation/unwind_fixture.dylib
python3 tests/test_publish.py
python3 tests/test_arena_publish.py
python3 tests/test_nib.py
xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -Itranslation/AppKit -framework Foundation translation/AppKit/NibArchive.m tests/test_nib_archive.m \
    -o build/emulation/test_nib_archive
python3 tests/test_nib_archive.py build/emulation/test_nib_archive
python3 tests/test_generic_build.py
python3 tests/test_classify.py
python3 tests/test_shim_stubs.py
python3 tests/test_embed_vulkan_runtime.py
python3 tests/test_shim_dependencies.py
python3 tests/test_metallib.py
python3 - <<'PYFIXTURE'
import sys
from pathlib import Path
sys.path.insert(0,'tests')
from test_metallib import library
# A legacy macOS container (AIR 2.0) and a current one (AIR 2.7, macOS 15).
data=bytearray(library());data[4:16]=bytes([1,128,2,0,2,0,0,0,0,0,0,0])
Path('build/emulation/container-fixture.metallib').write_bytes(data)
data=bytearray(library((2,7)));data[4:16]=bytes([1,128,2,0,8,0,0,0x81,15,0,0,0])
Path('build/emulation/container-fixture-current.metallib').write_bytes(data)
PYFIXTURE
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations -g -fsanitize=address,undefined \
    -Itranslation/Metal -framework Foundation translation/Metal/LibraryContainer.m tests/test_library_container.m \
    -o build/emulation/test_library_container
build/emulation/test_library_container build/emulation/container-fixture.metallib build/emulation/container-fixture-current.metallib
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations -O1 -g -fsanitize=address,undefined \
    -Itranslation/Metal tests/test_storage_modes.m -o build/emulation/test_storage_modes
build/emulation/test_storage_modes
xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -framework Foundation translation/CoreGraphics/DisplayModes.m tests/test_display_modes.m \
    -o build/emulation/test_display_modes
build/emulation/test_display_modes
xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -Itranslation/AppKit -framework Foundation translation/AppKit/ImageHints.m tests/test_image_hints.m \
    -o build/emulation/test_image_hints
build/emulation/test_image_hints
xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -Itranslation/AppKit -framework Foundation translation/AppKit/WindowFullscreen.m tests/test_window_fullscreen.m \
    -o build/emulation/test_window_fullscreen
build/emulation/test_window_fullscreen
# --metal-managed-storage on the Mac's own device, where Managed is valid: on, then off.
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations -O1 -g -fsanitize=address,undefined \
    -Itranslation/AKSupport -Itranslation/Metal -framework Foundation -framework Metal \
    translation/AKSupport/AKSupport.m translation/Metal/ManagedStorage.m tests/test_managed_storage.m \
    -o build/emulation/test_managed_storage
build/emulation/test_managed_storage --metal-managed-storage
build/emulation/test_managed_storage
# The Metal adapter's device-function wrappers: the fixture re-exports Metal as akMetal does.
xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g -dynamiclib -DAK_FIXTURE_LIBRARY -Itranslation/Metal \
    -framework Foundation -Wl,-reexport_framework,Metal tests/test_real_function.m -o build/emulation/libakMetalFixture.dylib
xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined -Itranslation/Metal \
    -framework Foundation -framework Metal tests/test_real_function.m -o build/emulation/test_real_function
build/emulation/test_real_function build/emulation/libakMetalFixture.dylib
python3 tests/test_shader_translation.py
python3 -m unittest tests.test_sign_guest_local
python3 -m unittest tests.test_build_signed_container

"${CC[@]}" runtime/GuestMemory.c runtime/GuestImage.c runtime/GuestFixups.c tests/test_fixups.c -o build/emulation/test_fixups
build/emulation/test_fixups
"${CC[@]}" runtime/GuestTLS.c runtime/GuestTLSArm64.S tests/test_tls.c tests/test_tls_arm64.S -o build/emulation/test_tls
build/emulation/test_tls

xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -Itranslation/AKSupport -framework Foundation translation/Carbon/Keyboard.m \
    translation/CoreServices/Keyboard.m tests/test_keyboard.m -o build/emulation/test_keyboard
build/emulation/test_keyboard

xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -Itranslation/AKSupport -Itranslation/AppKit -framework Foundation -framework CoreGraphics \
    translation/AKSupport/AKSupport.m translation/AppKit/Images.m tests/test_images.m -o build/emulation/test_images
build/emulation/test_images

xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -Itranslation/AKSupport -Itranslation/AppKit -framework Foundation -framework CoreGraphics \
    translation/AKSupport/AKSupport.m translation/AppKit/Images.m translation/AppKit/Drawing.m tests/test_drawing.m \
    -o build/emulation/test_drawing
build/emulation/test_drawing

xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -Itranslation/AKSupport -framework Foundation translation/AKSupport/AKSupport.m translation/CoreGraphics/Events.m \
    tests/test_quartz_events.m -o build/emulation/test_quartz_events
build/emulation/test_quartz_events

xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -Itranslation/AKSupport -framework Foundation translation/AppKit/TextInput.m tests/test_text_input.m \
    -o build/emulation/test_text_input
build/emulation/test_text_input

xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -Itranslation/AppKit -framework Foundation translation/AppKit/EventMonitors.m tests/test_event_monitors.m \
    -o build/emulation/test_event_monitors
build/emulation/test_event_monitors

bash tools/test_legacy_crypto.sh
"${CC[@]}" -Itranslation/Security translation/Security/Session.c tests/test_security_session.c -o build/emulation/test_security_session
build/emulation/test_security_session
"${CC[@]}" -Itranslation/CoreGraphics translation/CoreGraphics/Gamma.c tests/test_display_gamma.c -framework CoreGraphics -o build/emulation/test_display_gamma
build/emulation/test_display_gamma

xcrun clang -fobjc-arc -Wno-deprecated-declarations -framework Foundation -framework Security \
    tools/export_system_anchors.m -o build/emulation/export_system_anchors
build/emulation/export_system_anchors build/emulation/system-roots.plist
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -O1 -g -fsanitize=address,undefined -Itranslation/Security -framework Foundation \
    -framework Security translation/Security/Keychain.m tests/test_system_roots.m \
    -o build/emulation/test_system_roots
build/emulation/test_system_roots build/emulation/system-roots.plist
