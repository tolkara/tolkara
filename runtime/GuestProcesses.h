#pragma once
#include "GuestLink.h"
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

// Several processes of a compatibility runtime in this one (docs/MULTIPROCESS.md).
// Slot 0 is the launch itself: the executable and the libraries it carries. Each
// further slot holds its own placed copy of the runtime's libraries, and starts
// when the runtime spawns its own loader. What the copies share with the host
// process (the environment, signal handlers, threads, exit) is answered per slot
// here. With one slot nothing here is used and the guest binds as before.
enum { GP_MAX_PROCESSES = 8 };

typedef struct {
    GuestLinkSet *set;              // its placed libraries; slot 0: the launch's own
    uintptr_t pool_start, pool_end; // its share of the code pool, executable view
    uintptr_t pool_alias;           // the same memory's writable view
} GPSlotLayout;

// How the runtime starts in a slot: the entry its own copy exports, with the
// spawned command line. Called on the slot's first thread; does not return.
typedef void (*GPStart)(size_t slot, int argc, char **argv);

void gp_configure(size_t count, FILE *log, GPStart start);
// The code pool the slots share: each takes a range when it starts, sized by
// rules "pattern=MB;...;*=MB" matched (as substrings, ignoring case) against its
// command line, the first that matches winning. Once a slot enters guest code,
// its range remains retired until host exit; only pre-entry rollback returns it.
// Without rules each slot gets an equal share.
void gp_set_pool(uintptr_t start, uintptr_t end, uintptr_t alias, const char *rules);
// A range of the pool for a slot about to run this command line; false when the
// pool has no room. Sets the slot's layout pool fields.
bool gp_take_pool(size_t slot, int argc, char *const argv[]);
// Environment variables per program: rules "pattern>NAME=value NAME=value;..."
// matched as for the pool, the first that matches applying, set in the slot's
// environment (slot 0: the process environment) before the program starts.
void gp_set_environment_rules(const char *rules);
// ${LargeReserve} in a rule's values: an address range reserved at startup for
// one process's large reservations ("0x<start>-0x<end>"), empty if none.
void gp_set_large_reserve(uintptr_t start, uintptr_t end);
void gp_apply_environment_rules(size_t slot, int argc, char *const argv[]);
size_t gp_count(void);
bool gp_active(void);
void gp_set_layout(size_t slot, const GPSlotLayout *layout);
const GPSlotLayout *gp_layout(size_t slot);

// The slot whose placed library holds an address, or whose code pool share
// does; -1 when none. Safe in a signal handler.
int gp_slot_of_address(uintptr_t address);
// The slot the calling thread belongs to: as tagged when it was created, else
// by where `address` lies, else slot 0. Safe in a signal handler.
size_t gp_current_slot(uintptr_t address);

// The environment, per slot. Slot 0 is the process environment.
char *gp_getenv(size_t slot, const char *name);
int gp_setenv(size_t slot, const char *name, const char *value, int overwrite);
int gp_unsetenv(size_t slot, const char *name);
int gp_putenv(size_t slot, char *entry);
char ***gp_environ(size_t slot);

// Threads a slot's code creates are tagged with the slot and counted until
// TLS cleanup. Creation after process exit begins fails with EAGAIN.
int gp_pthread_create(size_t slot, pthread_t *thread, const pthread_attr_t *attributes,
                      void *(*start)(void *), void *argument);

// True only after exit was requested, TLS cleanup completed, and the kernel
// confirmed termination of every tracked native thread. This alone does not
// authorize range reuse: native adapter callbacks must also be retired.
bool gp_threads_terminated(size_t slot);

// A slot's signal handlers: one host handler per signal passes each signal to
// the slot of the thread it arrives on.
int gp_sigaction(size_t slot, int number, const struct sigaction *action, struct sigaction *old);

// The runtime spawning its own loader: the next free slot starts it, on a new
// thread, with this command line and environment. errno-style result.
int gp_spawn(char *const argv[], char *const envp[]);
// Host adapters can retire surfaces without invoking exited guest code.
void gp_set_exit_callback(void (*callback)(size_t));
// Experimental private-range reclamation, separate from single-use code pools.
// A host adapter check must confirm UI retirement and native callback drainage.
void gp_set_retirement_check(bool (*check)(size_t));
bool gp_reclaim_range(size_t slot);
// A slot's last code calling exit: that slot ends, the host process stays.
void gp_slot_exit(size_t slot, int code) __attribute__((noreturn));
