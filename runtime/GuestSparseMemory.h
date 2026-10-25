#pragma once
#include "GuestMemory.h"

// Software addresses are integers, never pointers into the host address space.
// Initialization reserves a bounded host backing arena and all metadata. Reads,
// writes and mapping operations allocate no host memory after initialization.
// Buffers passed to read/write must be ordinary host memory, not software VAs.
// Calls are serialized internally; destruction requires all users to stop.
typedef struct { void *implementation; } GMSparseMemory;
typedef struct {
    uint64_t reserved_bytes;
    uint64_t write_operations; // successful nonempty writes, including atomic updates
    size_t regions, resident_pages, capacity_pages;
} GMSparseStats;
typedef struct {
    uint64_t address, generation, mapping_generation;
    size_t size;
    bool valid;
} GMSparseExclusive;
typedef enum {
    GM_ATOMIC_ADD, GM_ATOMIC_CLEAR, GM_ATOMIC_XOR, GM_ATOMIC_SET,
    GM_ATOMIC_SIGNED_MAX, GM_ATOMIC_SIGNED_MIN, GM_ATOMIC_UNSIGNED_MAX,
    GM_ATOMIC_UNSIGNED_MIN, GM_ATOMIC_SWAP
} GMSparseAtomic;

GMResult gm_sparse_init(GMSparseMemory *memory, uint64_t base, uint64_t size,
                        size_t backing_bytes);
// Preallocate page-sized allocator blocks instead of one large mmap. Both
// backends allocate everything before signal handling and zero pages on use.
GMResult gm_sparse_init_blocks(GMSparseMemory *memory, uint64_t base, uint64_t size,
                               size_t backing_bytes);
void gm_sparse_destroy(GMSparseMemory *memory);
// Finds a free page-aligned range whose address modulo alignment equals offset.
// Like find_free, callers must map without replacement and retry GM_OVERLAP.
GMResult gm_sparse_find_aligned(GMSparseMemory *memory, uint64_t size, uint64_t alignment,
                                uint64_t offset, uint64_t *address);
GMResult gm_sparse_find_free(GMSparseMemory *memory, uint64_t size, uint64_t *address);
GMResult gm_sparse_map(GMSparseMemory *memory, uint64_t address, uint64_t size,
                       unsigned prot, unsigned maxprot, bool replace);
GMResult gm_sparse_unmap(GMSparseMemory *memory, uint64_t address, uint64_t size);
GMResult gm_sparse_protect(GMSparseMemory *memory, uint64_t address, uint64_t size,
                           unsigned prot);
GMResult gm_sparse_read(GMSparseMemory *memory, uint64_t address, void *buffer,
                        size_t size);
GMResult gm_sparse_write(GMSparseMemory *memory, uint64_t address,
                         const void *buffer, size_t size);
// Validate an API buffer before a syscall. Writable buffers obtain backing
// before the syscall consumes input; existing contents are preserved.
GMResult gm_sparse_prepare(GMSparseMemory *memory, uint64_t address, size_t size,
                           unsigned permissions);
GMResult gm_sparse_load_exclusive(GMSparseMemory *memory, uint64_t address,
                                  void *buffer, size_t size, GMSparseExclusive *monitor);
GMResult gm_sparse_store_exclusive(GMSparseMemory *memory, uint64_t address,
                                   const void *buffer, size_t size,
                                   GMSparseExclusive *monitor, bool *stored);
GMResult gm_sparse_compare_exchange(GMSparseMemory *memory, uint64_t address,
                                    const void *expected, const void *desired,
                                    void *previous, size_t size);
GMResult gm_sparse_atomic(GMSparseMemory *memory, uint64_t address, size_t size,
                          GMSparseAtomic operation, uint64_t operand, uint64_t *previous);
GMSparseStats gm_sparse_stats(GMSparseMemory *memory);
