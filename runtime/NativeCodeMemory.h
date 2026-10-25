#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Separate RX and RW views of shared pages. Guest addresses are not host pointers.
// This is storage for a future native loader/translator, not an execution engine.
typedef struct {
    void *executable;
    void *writable;
    size_t size;
    bool published;
    bool quarantined;
} NativeCodeMemory;

// Called once on newly allocated RX pages before the writable alias is enabled.
// The publisher must verify its own initialization handshake and return false if
// unavailable. Mapping success alone does not prove execution is permitted.
typedef bool (*NCPublish)(void *executable, size_t size, void *context);
// A ceiling on any one arena, whatever the device allows.
#define NC_MAX_ARENA (2048ull * 1024u * 1024u)
// The largest arena a launch accepts now: the ceiling, or what the system says
// is left to this process if that is less. Page aligned.
size_t nc_launch_limit(void);
// What External JIT first asks an enabler for: a quarter of what is left (the
// writable alias and the application's own allocations count too), at most
// the ceiling. Page aligned.
size_t nc_arena_limit(void);
// What the system says this process may still allocate.
size_t nc_available_memory(void);
// Zero-initialize memory before use. On error returns false and sets errno.
bool nc_create(NativeCodeMemory *memory, size_t size, NCPublish publish, void *context);
typedef enum { NC_REJECTED, NC_PREPARED, NC_UNCERTAIN } NCPreparation;
typedef NCPreparation (*NCPrepare)(void *executable, size_t size, void *context);
// For asynchronous helper publication: uncertainty transfers both mappings to
// quarantine, without enabling the writable alias. Retain that owner until
// process exit, and do not retry. nc_destroy deliberately cannot release it.
// NC_REJECTED means the helper can no longer access these mappings; only a
// confirmed prepared-and-detached receipt may produce NC_PREPARED.
bool nc_create_managed(NativeCodeMemory *memory, size_t size, NCPrepare prepare,
                       void *context, NativeCodeMemory *quarantine);
// Require the entire executable view below an exclusive address ceiling.
// Rejects an unsuitable mapping before calling the preparation service.
bool nc_create_managed_below(NativeCodeMemory *memory, size_t size, uintptr_t ceiling,
                             NCPrepare prepare, void *context, NativeCodeMemory *quarantine);
// Adopt a region made outside; it is ours from then.
bool nc_adopt(NativeCodeMemory *memory, void *executable, size_t size);
// Caller must ensure no thread is executing the range while it is being changed.
// Copies through RW, flushes caches, and keeps the RX protection unchanged.
bool nc_write(NativeCodeMemory *memory, size_t offset, const void *bytes, size_t size);
// Unmaps both views, adopted ones too; quarantine is kept.
void nc_destroy(NativeCodeMemory *memory);

// Allocate both views before one preparation transaction. Uncertainty retains
// both owners; neither executable view is published unless the pair succeeds.
typedef NCPreparation (*NCPreparePair)(void *, size_t, void *, size_t, void *);
bool nc_create_pair(NativeCodeMemory *first, size_t first_size, uintptr_t first_ceiling,
                    NativeCodeMemory *second, size_t second_size, NCPreparePair prepare,
                    void *context, NativeCodeMemory *first_quarantine, NativeCodeMemory *second_quarantine);
