#pragma once
#include "GuestSparseMemory.h"

// Architectural state for a single data-access instruction. The caller supplies
// the instruction word; this module does not fetch or modify executable code.
typedef struct {
    uint64_t x[31], sp, pc;
    unsigned char vector[32][16];
} GMMemoryRegisters;
typedef enum { GM_STEP_OK, GM_STEP_UNSUPPORTED, GM_STEP_FAULT } GMMemoryStep;
// Supported access instructions retire only after the entire access succeeds.
// On failure all registers and the PC are unchanged. Store failures are atomic.
GMMemoryStep gm_memory_step(GMSparseMemory *memory, uint32_t instruction,
                            GMMemoryRegisters *registers, GMResult *fault);

// Compatibility for translated x86 ordered loads/stores (LDAR/STLR/LDAPR).
// Allows unaligned addresses under the backing lock, including across pages.
// Exclusive and read-modify-write instructions retain their alignment rules.
GMMemoryStep gm_memory_step_x86_ordered(GMSparseMemory *memory, uint32_t instruction,
                                       GMMemoryRegisters *registers, GMResult *fault);
