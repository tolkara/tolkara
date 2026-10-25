#pragma once
#include "GuestSparseMemory.h"
#include <signal.h>
#include <stdio.h>
#include <sys/types.h>

// Process-lifetime opt-in. The caller restricts this to the authorized Cyberpunk or Steam
// profile (or our test fixtures). No guest instructions are patched or logged.
bool gsv_start(size_t backing_bytes, size_t force_threshold, int log_fd);
// Experimental backing placement, initialized before installing handlers.
bool gsv_start_blocks(size_t backing_bytes, size_t force_threshold, int log_fd);
void gsv_stop(void); // Only after every software-address user has stopped.
bool gsv_enabled(void);
// Set before guest entry, only for authorized translated-x86 compatibility.
void gsv_x86_ordered(bool allow);
bool gsv_address(const void *address);
uintptr_t gsv_address_end(void);
// Startup-only allocation comparison: prefer one exact large reservation size
// for native placement and route other large reservations through software.
void gsv_prefer_native_pool(size_t size);
// Startup-only comparison: route this exact anonymous reservation size to
// software, leaving other native-first decisions unchanged. Zero disables it.
void gsv_force_pool(size_t size);
// Register disjoint loader-owned arenas, serially before guest entry (up to 16).
// Overlap is refused even after invalidation. Both views remain
// alive until gsv_stop. Fetches read current bytes; there is no instruction cache.
bool gsv_code_alias(const void *executable, const void *readable, size_t size);
void gsv_forget_code_alias(const void *address, size_t size);
bool gsv_fetch_instruction(uint64_t pc, uint32_t *instruction);
// Let a process-aware dispatcher consume software-memory faults first.
// Returns false for unrelated signals; preserves errno in either case.
bool gsv_handle_signal(int number, siginfo_t *info, void *context);
int gsv_sigaction(int number, const struct sigaction *action, struct sigaction *old);
// Explicit software reservation for a compatibility runtime; never executable.
void *gsv_reserve_aligned(size_t size, size_t alignment, size_t offset, int prot);
void *gsv_map(void *address, size_t size, int prot, int flags, int fd, off_t offset);
int gsv_protect(void *address, size_t size, int prot);
int gsv_unmap(void *address, size_t size);
int gsv_advise(void *address, size_t size, int advice);
GMResult gsv_copy(void *destination, const void *source, size_t size);
GMResult gsv_fill(void *destination, int value, size_t size);
const char *gsv_string(const char *source, char *buffer, size_t capacity);
size_t gsv_strlen(const char *string);
size_t gsv_strnlen(const char *string, size_t limit);
int gsv_strcmp(const char *left, const char *right);
int gsv_strncmp(const char *left, const char *right, size_t limit);
int gsv_memcmp(const void *left, const void *right, size_t size);
void *gsv_memchr(const void *bytes, int value, size_t size);
char *gsv_strchr(const char *string, int value);
ssize_t gsv_read(int fd, void *buffer, size_t size);
ssize_t gsv_pread(int fd, void *buffer, size_t size, off_t offset);
ssize_t gsv_write(int fd, const void *buffer, size_t size);
ssize_t gsv_pwrite(int fd, const void *buffer, size_t size, off_t offset);
size_t gsv_fread(void *buffer, size_t size, size_t count, FILE *file);
size_t gsv_fwrite(const void *buffer, size_t size, size_t count, FILE *file);
GMSparseStats gsv_stats(void);
uint64_t gsv_fault_count(void);

// Aggregate runtime fetch paths only; no application instructions or PCs.
typedef struct { uint64_t alias_fetches, checked_fetches; } GSVFetchStats;
GSVFetchStats gsv_fetch_stats(void);
