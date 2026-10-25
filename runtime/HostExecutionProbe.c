#include "HostExecutionProbe.h"
#include "NativeCodeMemory.h"
#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

// Debugger rendezvous for publishing this host-owned sample. The normal runtime
// does nothing here. The opt-in LLDB helper initializes a fresh page with our
// sample or re-writes identical sample bytes. It never edits the guest image.
__attribute__((noinline, used, visibility("default")))
void host_debugger_publish_code(void *address, size_t size) {
    __asm__ volatile("" : : "r"(address), "r"(size) : "memory");
}

static bool publish_sample(void *rx, size_t size, void *context) {
    FILE *log = context;
    fprintf(log, "[execution] RX view and shared alias allocated; debugger publication point\n"); fflush(log);
    host_debugger_publish_code(rx, size);
    const uint32_t handshake[] = {0x52800540, 0xd65f03c0};
    // Missing debugger assistance fails before attempting an invalid code page.
    return !memcmp(rx, handshake, sizeof handshake);
}

static HPResult dual_mapping_probe(FILE *log) {
    HPResult result = {0};
    size_t size = (size_t)getpagesize();
    NativeCodeMemory memory = {0};
    fprintf(log, "[execution] begin mode=dual-map page_size=%zu; host sample only\n", size); fflush(log);
    if (!nc_create(&memory, size, publish_sample, log)) {
        result.allocation_errno = errno;
        fprintf(log, "[execution] dual mapping/publication unavailable errno=%d\n", errno);
        goto done;
    }
    const uint32_t sample[] = {0x52800540, 0xd65f03c0};
    if (!nc_write(&memory, 0, sample, sizeof sample) || memcmp(memory.executable, sample, sizeof sample)) {
        fprintf(log, "[execution] aliases do not share written code\n"); goto done;
    }
    fprintf(log, "[execution] calling generated arm64 sample; expected=42\n"); fflush(log);
    int (*function)(void) = (int (*)(void))memory.executable;
    result.first_value = function(); result.executable = result.first_value == 42;
    fprintf(log, "[execution] first return=%d\n", result.first_value); fflush(log);
    if (!result.executable) goto done;
    const uint32_t rewritten = 0x5280a720;
    if (!nc_write(&memory, 0, &rewritten, sizeof rewritten)) goto done;
    fprintf(log, "[execution] calling rewritten sample without another debugger publication; expected=1337\n"); fflush(log);
    result.rewritten_value = function(); result.rewrite_executable = result.rewritten_value == 1337;
    fprintf(log, "[execution] rewritten return=%d\n", result.rewritten_value);
    if (!result.rewrite_executable) goto done;
    // Exercise repeated host writes and instruction-cache visibility after the
    // one-time debugger initialization, including after detaching if requested.
    for (unsigned i = 0; i < 256; i++) {
        uint32_t instruction = 0x52800000 | (i << 5); // mov w0, #i
        if (!nc_write(&memory, 0, &instruction, sizeof instruction) || function() != (int)i) {
            result.rewrite_executable = false;
            fprintf(log, "[execution] repeated rewrite failed at %u\n", i); goto done;
        }
    }
    fprintf(log, "[execution] repeated rewrite/execute cycles=256 PASS\n");
done:
    nc_destroy(&memory);
    fprintf(log, "[execution] result execute=%s rewrite=%s\n", result.executable ? "PASS" : "FAIL", result.rewrite_executable ? "PASS" : "FAIL"); fflush(log);
    return result;
}

static int call_sample(void *code, size_t size, FILE *log, const char *stage, int expected) {
    sys_icache_invalidate(code, size);
    fprintf(log, "[arena-probe] %s: calling sample, expected=%d\n", stage, expected); fflush(log);
    int value = ((int (*)(void))code)();
    fprintf(log, "[arena-probe] %s: returned %d\n", stage, value); fflush(log);
    return value;
}

HPArenaResult arena_execution_probe(void *executable, void *writable, size_t size, FILE *log) {
    HPArenaResult result = {0};
#if defined(__aarch64__)
    const uint32_t ret = 0xd65f03c0;
    uint32_t sample[2] = {0x52800540, ret}; // mov w0, #42; ret
    fprintf(log, "[arena-probe] begin rx=%p rw=%p size=%zu; host samples only\n", executable, writable, size); fflush(log);
    memcpy(writable, sample, sizeof sample);
    sys_dcache_flush(writable, sizeof sample);
    result.alias_execute = call_sample(executable, sizeof sample, log, "alias write", 42) == 42;
    if (!result.alias_execute) goto done;
    sample[0] = 0x5280a720; // mov w0, #1337
    memcpy(writable, sample, sizeof sample);
    sys_dcache_flush(writable, sizeof sample);
    result.alias_rewrite = call_sample(executable, sizeof sample, log, "alias rewrite", 1337) == 1337;
    if (!result.alias_rewrite) goto done;
    {
        // Several processes in one (docs/MULTIPROCESS.md) could share code pages if
        // prepared pages also run where they are mapped a second time.
        vm_address_t second = 0;
        vm_prot_t current = 0, maximum = 0;
        fprintf(log, "[arena-probe] remap: the RX view's page mapped again elsewhere\n"); fflush(log);
        kern_return_t kr = vm_remap(mach_task_self(), &second, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                                    (vm_address_t)executable, FALSE, &current, &maximum, VM_INHERIT_NONE);
        if (kr != KERN_SUCCESS) result.remap_errno = kr;
        else if (mprotect((void *)second, size, PROT_READ | PROT_EXEC)) result.remap_errno = errno;
        else {
            fprintf(log, "[arena-probe] remap: second mapping %p protection %#x/%#x\n", (void *)second, current, maximum); fflush(log);
            sample[0] = 0x528006e0; // mov w0, #55
            memcpy(writable, sample, sizeof sample);
            sys_dcache_flush(writable, sizeof sample);
            result.remap_execute = call_sample((void *)second, sizeof sample, log, "remapped", 55) == 55;
        }
        if (kr == KERN_SUCCESS) vm_deallocate(mach_task_self(), second, size);
        fprintf(log, "[arena-probe] remap: %s error=%d\n", result.remap_execute ? "PASS" : "FAIL", result.remap_errno); fflush(log);
    }
    fprintf(log, "[arena-probe] direct: RX view to RW\n"); fflush(log);
    if (mprotect(executable, size, PROT_READ | PROT_WRITE)) { result.direct_errno = errno; goto rwx; }
    sample[0] = 0x528000e0; // mov w0, #7
    memcpy(executable, sample, sizeof sample);
    fprintf(log, "[arena-probe] direct: written, back to RX\n"); fflush(log);
    if (mprotect(executable, size, PROT_READ | PROT_EXEC)) { result.direct_errno = errno; goto rwx; }
    result.direct_rewrite = call_sample(executable, sizeof sample, log, "direct rewrite", 7) == 7;
    if (!result.direct_rewrite) goto done;
    sample[0] = 0x52800c60; // mov w0, #99
    memcpy(writable, sample, sizeof sample);
    sys_dcache_flush(writable, sizeof sample);
    result.alias_after_direct = call_sample(executable, sizeof sample, log, "alias after direct", 99) == 99;
rwx:
    fprintf(log, "[arena-probe] rwx: RX view to RWX\n"); fflush(log);
    result.rwx_errno = mprotect(executable, size, PROT_READ | PROT_WRITE | PROT_EXEC) ? errno : 0;
    fprintf(log, "[arena-probe] rwx: %s errno=%d\n", result.rwx_errno ? "denied" : "allowed", result.rwx_errno); fflush(log);
    mprotect(executable, size, PROT_READ | PROT_EXEC);
done:
    fprintf(log, "[arena-probe] result alias=%s rewrite=%s direct=%s(errno %d) after-direct=%s rwx-errno=%d\n",
            result.alias_execute ? "PASS" : "FAIL", result.alias_rewrite ? "PASS" : "FAIL", result.direct_rewrite ? "PASS" : "FAIL",
            result.direct_errno, result.alias_after_direct ? "PASS" : "FAIL", result.rwx_errno);
    fflush(log);
#else
    (void)executable; (void)writable; (void)size;
    fprintf(log, "[arena-probe] unsupported host architecture; arm64 required\n"); fflush(log);
#endif
    return result;
}

HPResult host_execution_probe(HPMode mode, FILE *log) {
    HPResult result = {0};
#if defined(__aarch64__)
    if (mode == HP_DUAL_MAPPING) return dual_mapping_probe(log);
    const size_t size = (size_t)getpagesize();
    const int flags = MAP_PRIVATE | MAP_ANON;
    const int write_prot = PROT_READ | PROT_WRITE;
    const int execute_prot = PROT_READ | PROT_EXEC;
    const int initial_prot = mode == HP_READ_WRITE_EXECUTE ? write_prot | PROT_EXEC : write_prot;
    fprintf(log, "[execution] begin mode=%s page_size=%zu; host sample only\n",
            mode == HP_READ_WRITE_EXECUTE ? "rwx" : "write-then-execute", size);
    fflush(log);
    // MAP_JIT acceptance is useful evidence, but does not prove executability.
    errno = 0;
    void *jit = mmap(NULL, size, write_prot | PROT_EXEC, flags | MAP_JIT, -1, 0);
    int jit_errno = errno;
    fprintf(log, "[execution] MAP_JIT allocation=%s errno=%d\n", jit == MAP_FAILED ? "denied" : "accepted", jit == MAP_FAILED ? jit_errno : 0);
    if (jit != MAP_FAILED) munmap(jit, size);
    errno = 0;
    void *code = mmap(NULL, size, initial_prot, flags, -1, 0);
    if (code == MAP_FAILED) {
        result.allocation_errno = errno;
        fprintf(log, "[execution] anonymous allocation failed errno=%d (%s)\n", errno, strerror(errno));
        fflush(log); return result;
    }
    const uint32_t sample[] = {0x52800540, 0xd65f03c0}; // mov w0, #42; ret
    memcpy(code, sample, sizeof sample);
    if (mode == HP_WRITE_THEN_EXECUTE && mprotect(code, size, execute_prot)) {
        result.protection_errno = errno;
        fprintf(log, "[execution] RW->RX denied errno=%d (%s)\n", errno, strerror(errno));
        goto done;
    }
    host_debugger_publish_code(code, size);
    sys_icache_invalidate(code, sizeof sample);
    fprintf(log, "[execution] calling generated arm64 sample; expected=42\n"); fflush(log);
    int (*function)(void) = (int (*)(void))code;
    result.first_value = function();
    result.executable = result.first_value == 42;
    fprintf(log, "[execution] first return=%d\n", result.first_value); fflush(log);
    if (!result.executable) goto done;
    if (mode == HP_WRITE_THEN_EXECUTE && mprotect(code, size, write_prot)) {
        result.protection_errno = errno;
        fprintf(log, "[execution] RX->RW denied errno=%d (%s)\n", errno, strerror(errno));
        goto done;
    }
    const uint32_t rewritten = 0x5280a720; // mov w0, #1337
    memcpy(code, &rewritten, sizeof rewritten);
    if (mode == HP_WRITE_THEN_EXECUTE && mprotect(code, size, execute_prot)) {
        result.protection_errno = errno;
        fprintf(log, "[execution] second RW->RX denied errno=%d (%s)\n", errno, strerror(errno));
        goto done;
    }
    host_debugger_publish_code(code, size);
    sys_icache_invalidate(code, sizeof sample);
    fprintf(log, "[execution] calling rewritten sample; expected=1337\n"); fflush(log);
    result.rewritten_value = function();
    result.rewrite_executable = result.rewritten_value == 1337;
    fprintf(log, "[execution] rewritten return=%d\n", result.rewritten_value);
done:
    munmap(code, size);
    fprintf(log, "[execution] result execute=%s rewrite=%s\n", result.executable ? "PASS" : "FAIL", result.rewrite_executable ? "PASS" : "FAIL");
    fflush(log);
#else
    (void)mode;
    fprintf(log, "[execution] unsupported host architecture; arm64 required\n"); fflush(log);
#endif
    return result;
}
