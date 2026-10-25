#pragma once
#include <stdbool.h>
#include <stdio.h>

typedef enum { HP_WRITE_THEN_EXECUTE, HP_READ_WRITE_EXECUTE, HP_DUAL_MAPPING } HPMode;
typedef struct {
    bool executable;
    bool rewrite_executable;
    int allocation_errno, protection_errno;
    int first_value, rewritten_value;
} HPResult;
// Opt-in diagnostic: executes only our two-instruction arm64 sample. A kernel
// code-signing rejection can terminate the process; stage logs are flushed first.
// A passing result applies to this process/launch mode only, not future launches.
HPResult host_execution_probe(HPMode mode, FILE *log);

typedef struct {
    bool alias_execute, alias_rewrite;       // written through the RW alias, run from the RX view
    bool direct_rewrite;                     // the RX view made RW, written, made RX again, run
    bool alias_after_direct;                 // then the alias again
    bool remap_execute;                      // the same pages mapped a second time elsewhere, run there
    int remap_errno;                         // vm_remap or mprotect error of that stage (0 if it ran)
    int direct_errno, rwx_errno;             // mprotect errors of the direct stage and of RWX (0 if allowed)
} HPArenaResult;
// Opt-in diagnostic on one spare page of a prepared arena (offset, page
// aligned): what a runtime that generates code may do there after the helper
// detached. Runs only our own samples; each stage is logged and flushed first,
// as a rejection can end the process.
HPArenaResult arena_execution_probe(void *executable, void *writable, size_t size, FILE *log);
