# Compact allocator experiment

These patches are against the local experimental FEX/rpmalloc fork, not arbitrary upstream versions. They are not automatically applied by the build.

- `compact-spans-cmake.patch`: apply from the FEX root. ARM64EC TEB-backed builds use 1 MiB spans instead of 16 MiB.
- `compact-rpmalloc.patch`: apply from `External/rpmalloc`. Limit pooled large blocks to 512 KiB; larger requests use the existing huge allocation path. Allow substantial huge reallocations to shrink. Correct the full-to-empty transition for a one-block page.
- `bounded-rpmalloc-tests.patch`: apply to a temporary copy of `test/main.c`. Retain the upstream array capacities, reduce the quadratic allocation loops, cap concurrency, use the FEX 64 KiB page configuration, omit global malloc-override tests (FEX calls rpmalloc explicitly), and keep each first-class-heap thread argument alive until joined. Both baseline and compact configurations pass this bounded suite under ASan/UBSan on the Mac. This is not the full unmodified upstream suite or a device result.

Example compile after generating the patched test source as `/tmp/rpmalloc-main.c`, from the FEX root:

```sh
xcrun clang -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
  -DENABLE_ASSERTS=1 -DENABLE_OVERRIDE=0 -DENABLE_DECOMMIT=1 \
  -DRPMALLOC_FIRST_CLASS_HEAPS=1 -DRPMALLOC_COMPACT_SPANS=1 \
  '-DSPAN_SIZE=(1 * 1024 * 1024)' -DLARGE_PAGE_SIZE_SHIFT=20 \
  -IExternal/rpmalloc/rpmalloc -IExternal/rpmalloc/test \
  External/rpmalloc/rpmalloc/rpmalloc.c /tmp/rpmalloc-main.c \
  External/rpmalloc/test/thread.c -o /tmp/rpmalloc-tests
/tmp/rpmalloc-tests
```

The baseline comparison uses the original allocator source, omits RPMALLOC_COMPACT_SPANS, and sets SPAN_SIZE to 16 MiB and LARGE_PAGE_SIZE_SHIFT to 24. These tests validate allocator behavior; Steam capacity and physical iPad execution require separate checks.

`compact-l1-cache.patch` applies at the FEX root. It caps the L1 lookup cache at 64K entries (1 MiB) for the existing FEX_TEB_TSD_OFFSET bounded Darwin build. The old maximum reserved 16 MiB per thread even with dynamic growth enabled. This changes the cache capacity, not the address comparison: L1 collisions still compare the full guest address and fall back to shared mappings. Device performance and execution are unverified.

`oneblock_probe.c` is a focused allocator regression using two maximum-class allocations (now 512 KiB each). With compact spans and the old free-list transition, it asserts in page_available_to_free; with the corrected transition it passes ASan/UBSan. Compile it instead of the bounded upstream test source in the command above.

The smaller-L1 emulator passed `testguest/windows/fex_l1_probe.c` plus `.S`: eight threads alternate one million calls to two owned x86-64 functions exactly 64 KiB apart (same L1 index), checking every result. Build with x86_64-w64-mingw32-clang -O2 -Wall -Wextra -Werror and run through the experimental Wine/FEX runtime. It passes on the Mac with L2 disabled and the bounded 4 GiB data region. This is a focused collision smoke test, not comprehensive FEX validation.

The compact patch now also uses 512 KiB medium pages (previously 4 MiB), so multiple medium-class pages can occupy a span. The bounded ASan/UBSan suite passes again with this change, including the actual 64 KiB allocator page configuration. Steam capacity results are recorded separately in docs/FULLSCREEN_PROCESSES.md.

Current span size is 1 MiB with 1 MiB large pages and 512 KiB medium pages. The largest pooled block is 512 KiB; larger allocations retain the existing huge path. The bounded ASan/UBSan suite passes with this configuration as well. Earlier 4 MiB controls remain documented as intermediate results.

## Translation scratch-buffer reuse

`immediate-scratch-reuse.patch` returns a scratch buffer to the existing shared pool at DelayedDisownBuffer in bounded Darwin builds. It preserves the existing ownership protocol and buffer sizes, trading per-thread reuse speed for smaller startup reservations. It does not reclaim a buffer while owned. Apply at the FEX root.

`threadpool_probe.cpp` uses the actual 5000 ms / 500-use parameters. Thirty-two clients each claim/release twice: the original policy allocates 32 backing buffers and fails the one-buffer assertion; the patched policy allocates one. Eight concurrent clients each perform 1000 claims, yield while owning buffers, and check distinct contents before releasing. The patched policy passes ASan/UBSan, as does the translated x86-64 L1/thread fixture.

For the native Mac fixture, provide a temporary `malloc.h` containing `#include <stdlib.h>` and `#include <malloc/malloc.h>`. Compile with clang++ -std=c++20 -O1 -g -fsanitize=address,undefined -DASSERTIONS_ENABLED=1 -DFEX_TEB_TSD_OFFSET=0x17f8, the FEXCore/include and External/fmt/include paths, and -DMADV_HUGEPAGE=MADV_NORMAL -DMADV_NOHUGEPAGE=MADV_NORMAL for unused Linux advice helpers. The fixture uses malloc-backed storage; these substitutions do not validate virtual-memory advice behavior.

## Bounded decoder buffer

`bounded-decoder-buffer.patch` sizes the decoder scratch buffer to the configured instruction limit (capped at the existing 65536-entry maximum) on bounded Darwin builds. The decode loop checks capacity before writing an entry. Other builds retain the original capacity. Apply at the FEX root.

The owned `testguest/windows/decoder_block_probe.c` and `.S` fixture executes a 24000-instruction arithmetic sequence across eight threads and compares results with a C reference. It passes through Wine/FEX with FEX_MAXINST=17, exercising repeated block boundaries. This is a focused correctness check, not a full decoder test suite. Steam still fails before ReadyToRender with both the default limit and FEX_MAXINST=1000/FEX_MULTIBLOCK=0; see the capacity log in docs/FULLSCREEN_PROCESSES.md.

## 512 KiB span follow-up

`half-megabyte-spans.patch` applies at the FEX root after the compact allocator and CMake patches. It reduces spans and large pages to 512 KiB, keeps medium pages at 512 KiB, and drops the 512 KiB pooled class because its header would no longer fit. The largest pooled class becomes 448 KiB; larger requests use the existing huge path. This is the current experimental build configuration.

The bounded allocator suite passes ASan/UBSan with SPAN_SIZE=(512 * 1024), LARGE_PAGE_SIZE_SHIFT=19, and the other flags above. The focused full-to-empty fixture also passes with its two request sizes changed to 448 KiB. Both translated decoder-boundary and L1-collision/thread fixtures pass against the resulting Wine/FEX build.

`minimum-l1-cache.patch` applies after `compact-l1-cache.patch` at the FEX root. It caps the bounded-host L1 cache at the existing 8K-entry minimum (128 KiB), retaining full-address collision checks and fallback mappings. The translated eight-thread L1 collision fixture and long-decoder fixture pass. Cache performance under application workloads is unverified.

## Page-backed resource ownership

`pmr-release-on-destruction.patch` adds the missing destructor release to named_monotonic_page_buffer_resource. Its BufferData list stored raw backing pointers, so destruction previously destroyed list entries without calling VirtualFree. This resource backs translated-code block-link maps. Apply at the FEX root.

`pmr_probe.cpp` substitutes counted, aligned backing allocations. The baseline returns 1 after observing seven live backing regions following destruction. The patched resource passes 100 construction/destruction rounds under ASan/UBSan, including explicit release, repeated release, aligned allocation, and reuse after release. Compile with the same native include paths and advice substitutions as threadpool_probe.cpp, omitting FEX_TEB_TSD_OFFSET. The test establishes ownership correctness; Steam impact is measured separately.

## Serialized translation experiment

`serialized-translation.patch` adds a context-wide compilation mutex only for FEX_TEB_TSD_OFFSET builds. CompileBlock and CompileSingleStep acquire it after the existing signal-deferring invalidation guard and before claiming scratch buffers. This trades concurrent translation for a lower peak number of owned scratch buffers; guest execution remains concurrent. Apply at the FEX root.

The owned `testguest/windows/code_invalidation_probe.c` fixture has eight threads, each repeatedly writing its own six-byte x86 test function, switching protection, flushing instructions, and verifying the new return value for 100 iterations. It passes before and after serialization. The existing threaded L1 collision and decoder fixtures also pass with serialization. These focused tests do not establish all exception/signal paths or application performance.

`recycle-code-buffers.patch` applies at the FEX root (Windows builds only; it also carries the FEX_INITIALCODEBUFFERSIZE option). A retired code buffer is kept and handed to the next buffer of the same size, instead of being released to Wine. The iPad's prepared code pool never hands out a released range again (WINEJITPOOLNOREUSE=1), so each code-cache refill used new pool space. Steam's steam.exe exhausted its 150 MiB within minutes of startup. FEX then spun forever: a failed allocation left an empty buffer, which the JIT's allocation loop immediately cleared and replaced. Without room, the constructor now sleeps until another thread retires a buffer, logging once a minute. A recycled buffer keeps the protections FEX first gave it, guard page included.
