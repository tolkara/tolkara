#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
// Development startup diagnostic. Requires debugger publication of a fresh
// runtime arena, and never changes the packaged original executable.
bool ng_initialize(const char *path, const char *frameworks, const char *library_map, FILE *log, bool full_startup);
// What startup is doing now, for a status drawn while application code holds
// the main thread: a fixed description (NULL before ng_initialize), parts done
// of total (0 of 0 when not counted), and since when (mach_absolute_time).
// Any thread.
typedef struct { const char *step; unsigned long long done, total; uint64_t since; } NGStartupStep;
NGStartupStep ng_startup_step(void);
// Command-line arguments after the executable path (argv[1..]), for a
// compatibility runtime started from a profile. Copied; at most 64 of 4096
// bytes. Call before ng_initialize; default: none.
void ng_set_arguments(const char *const *arguments, size_t count);
// Host-only cleanup before a guest exits; never reads application memory.
// Install before guest entry. A nonzero exit remains an error exit.
typedef void (*NGExitObserver)(int code, void *context);
void ng_set_exit_observer(NGExitObserver observer, void *context);
// Libraries a compatibility runtime opens by path instead of linking, placed
// with the executable as if it carried them (gl_carry): absolute paths inside
// root, the runtime folder, which then counts as the application's folder.
// Copied; at most 64. Call before ng_initialize; default: none.
void ng_set_libraries(const char *root, const char *const *paths, size_t count);
// Prepared executable memory beyond the images, for a runtime that writes its
// own code (a JIT): bytes, rounded up to pages. Once the arena is ready,
// ${CodePool} in the environment's values stands for it, as
// 0x<start>-0x<end>@0x<writable alias>. Call before ng_initialize; default: none.
void ng_set_code_pool(size_t size);
// Developer service: select our integrated helper before the process's one
// permitted startup. Fails if Local signing was already selected.
bool ng_use_local_authorization(void);
// Local signing: dlopen a page container signed with the user's own identity
// (it carries the guest's final executable pages), validate it against the
// guest, and vm_remap its pages into the arena instead of asking the developer
// service to prepare memory. Call before ng_initialize. On failure, writes a
// reason to error (startup already attempted, Developer service already
// selected, empty or overlong path).
bool ng_use_signed_image(const char *container_path, char *error, size_t error_size);
// Prepared outside the app; accepted only if really executable.
bool ng_use_external_authorization(void);
// Ask an attached debugger for the arena now.
bool ng_reserve_arena(FILE *log);
// Whether an arena is already prepared for the launch.
bool ng_arena_reserved(void);
