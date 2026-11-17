#include "GuestProcesses.h"
#include "GuestSoftwareVM.h"
#include <crt_externs.h>
#include <errno.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mman.h>
#include <sys/ucontext.h>
#include <unistd.h>

typedef struct GPThreadRecord {
    mach_port_t port;
    struct GPThreadRecord *next;
} GPThreadRecord;

typedef struct {
    GPSlotLayout layout;
    char **environment;             // slots after the first: their own, NULL-terminated
    size_t environment_count;
    pthread_mutex_t lock;           // for the environment
    atomic_bool started;
    pthread_mutex_t threads_lock;
    GPThreadRecord *threads;
    atomic_bool thread_tracking_failed;
    atomic_uint_fast64_t threads_state; // exit flag and live count, updated together
} GPSlot;

static GPSlot slots[GP_MAX_PROCESSES];

// The shared code pool: free ranges, first fit.
enum { GP_POOL_RANGES = 64 };
static struct { uintptr_t start, end; } pool_free[GP_POOL_RANGES];
static size_t pool_free_count;
// The pool's ranges as they were given, each with its writable view.
enum { GP_POOL_PARTS = 4 };
static struct { uintptr_t start, end, alias; } pool_parts[GP_POOL_PARTS];
static size_t pool_part_count;
static char pool_rules[1024];
static char environment_rules[2048];
static char large_reserve[64];
static pthread_mutex_t pool_lock = PTHREAD_MUTEX_INITIALIZER;
static size_t slot_count = 1;
static FILE *log_file;
static GPStart start_slot;
static pthread_key_t slot_key;      // value: slot + 1

#define LOG(...) do { if (log_file) { fprintf(log_file, __VA_ARGS__); fflush(log_file); } } while (0)

// A single atomic state closes creation vs. exit without a lock in the exit
// path, which can be reached from Wine signal handling.
#define GP_THREADS_EXITED (UINT64_C(1) << 63)
static size_t live_threads(size_t slot) {
    return (size_t)(atomic_load(&slots[slot].threads_state) & ~GP_THREADS_EXITED);
}
// TLS destructors still run on the departing stack. Zero is diagnostic only;
// it does not permit unmapping stacks or pending adapter callback state here.
static void thread_finished(void *tag) {
    size_t slot = (uintptr_t)tag - 1;
    uint_fast64_t previous = atomic_fetch_sub(&slots[slot].threads_state, 1);
    size_t remaining = (size_t)((previous & ~GP_THREADS_EXITED) - 1);
    if (previous & GP_THREADS_EXITED)
        LOG("[processes] slot %zu: tracked thread cleanup, %zu still live\n", slot, remaining);
}

void gp_configure(size_t count, FILE *log, GPStart start) {
    if (count < 1) count = 1;
    if (count > GP_MAX_PROCESSES) count = GP_MAX_PROCESSES;
    slot_count = count;
    log_file = log;
    start_slot = start;
    for (size_t i = 0; i < GP_MAX_PROCESSES; i++) {
        pthread_mutex_init(&slots[i].lock, NULL);
        pthread_mutex_init(&slots[i].threads_lock, NULL);
    }
    atomic_store(&slots[0].started, true);
    if (count > 1) pthread_key_create(&slot_key, thread_finished);
}
size_t gp_count(void) { return slot_count; }
bool gp_active(void) { return slot_count > 1; }
void gp_set_layout(size_t slot, const GPSlotLayout *layout) {
    if (slot < GP_MAX_PROCESSES && layout) slots[slot].layout = *layout;
}
const GPSlotLayout *gp_layout(size_t slot) { return slot < GP_MAX_PROCESSES ? &slots[slot].layout : NULL; }

int gp_slot_of_address(uintptr_t address) {
    for (size_t i = 0; i < slot_count; i++) {
        const GPSlotLayout *layout = &slots[i].layout;
        if (layout->pool_end > layout->pool_start && address >= layout->pool_start && address < layout->pool_end)
            return (int)i;
        if (layout->set && gl_library_at(layout->set, address)) return (int)i;
    }
    return -1;
}
size_t gp_current_slot(uintptr_t address) {
    if (slot_count > 1) {
        uintptr_t tag = (uintptr_t)pthread_getspecific(slot_key);
        if (tag) return tag - 1;
    }
    int slot = gp_slot_of_address(address);
    return slot > 0 ? (size_t)slot : 0;
}

// --- The code pool -----------------------------------------------------------

void gp_set_pool(uintptr_t start, uintptr_t end, uintptr_t alias, const char *rules) {
    pthread_mutex_lock(&pool_lock);
    pool_part_count = pool_free_count = end > start;
    pool_parts[0].start = start; pool_parts[0].end = end; pool_parts[0].alias = alias;
    pool_free[0].start = start; pool_free[0].end = end;
    snprintf(pool_rules, sizeof pool_rules, "%s", rules ? rules : "");
    pthread_mutex_unlock(&pool_lock);
}
bool gp_add_pool(uintptr_t start, uintptr_t end, uintptr_t alias) {
    pthread_mutex_lock(&pool_lock);
    bool ok = end > start && pool_part_count && pool_part_count < GP_POOL_PARTS && pool_free_count < GP_POOL_RANGES;
    for (size_t i = 0; ok && i < pool_part_count; i++) ok = end <= pool_parts[i].start || start >= pool_parts[i].end;
    if (ok) {
        pool_parts[pool_part_count].start = start; pool_parts[pool_part_count].end = end; pool_parts[pool_part_count++].alias = alias;
        pool_free[pool_free_count].start = start; pool_free[pool_free_count++].end = end;
    }
    pthread_mutex_unlock(&pool_lock);
    return ok;
}
static bool contains_ignoring_case(const char *text, const char *pattern, size_t length) {
    for (; *text; text++) if (!strncasecmp(text, pattern, length)) return true;
    return false;
}
// Megabytes the rules give this command line; 0 when none matches.
static size_t rule_size(const char *command) {
    const char *rule = pool_rules;
    while (*rule) {
        const char *end = strchr(rule, ';'), *equals;
        if (!end) end = rule + strlen(rule);
        equals = memchr(rule, '=', (size_t)(end - rule));
        // The last '=' in the rule separates the size: patterns may hold '='.
        for (const char *p = equals; p && p < end; p++) if (*p == '=') equals = p;
        if (equals) {
            size_t length = (size_t)(equals - rule);
            if ((length == 1 && *rule == '*') || (length && contains_ignoring_case(command, rule, length)))
                return strtoul(equals + 1, NULL, 10);
        }
        rule = *end ? end + 1 : end;
    }
    return 0;
}
bool gp_take_pool(size_t slot, int argc, char *const argv[]) {
    char command[2048] = "";
    size_t used = 0;
    for (int i = 0; i < argc && argv[i]; i++)
        used += (size_t)snprintf(command + used, used < sizeof command ? sizeof command - used : 0, "%s%s", i ? " " : "", argv[i]);
    pthread_mutex_lock(&pool_lock);
    size_t total = 0;
    for (size_t i = 0; i < pool_free_count; i++) total += pool_free[i].end - pool_free[i].start;
    size_t page = (size_t)getpagesize(), size = rule_size(command) << 20;
    if (!size) {
        // An equal share of what was there to begin with, for each slot not started yet.
        size_t waiting = 0;
        for (size_t i = 0; i < slot_count; i++) if (!slots[i].layout.pool_end) waiting++;
        size = waiting ? total / waiting : 0;
    }
    size = size / page * page;
    bool ok = false;
    for (size_t i = 0; size && i < pool_free_count && !ok; i++) {
        if (pool_free[i].end - pool_free[i].start < size) continue;
        GPSlotLayout *layout = &slots[slot].layout;
        layout->pool_start = pool_free[i].start;
        layout->pool_end = pool_free[i].start + size;
        for (size_t part = 0; part < pool_part_count; part++)
            if (layout->pool_start >= pool_parts[part].start && layout->pool_end <= pool_parts[part].end)
                layout->pool_alias = pool_parts[part].alias + (layout->pool_start - pool_parts[part].start);
        pool_free[i].start += size;
        ok = true;
    }
    pthread_mutex_unlock(&pool_lock);
    if (ok) LOG("[processes] slot %zu: %zu MiB of the code pool for %.120s\n", slot, size >> 20, command);
    else LOG("[processes] slot %zu: the code pool has no room for %zu MiB (%zu MiB free)\n", slot, size >> 20, total >> 20);
    return ok;
}
// Back to the free list, merged with its neighbours.
static void give_back_pool(size_t slot) {
    GPSlotLayout *layout = &slots[slot].layout;
    if (layout->pool_end <= layout->pool_start) return;
    pthread_mutex_lock(&pool_lock);
    uintptr_t start = layout->pool_start, end = layout->pool_end, low = start, high = end;
    // Merged only inside its own range: two ranges that touch have different views.
    for (size_t part = 0; part < pool_part_count; part++)
        if (start >= pool_parts[part].start && end <= pool_parts[part].end) { low = pool_parts[part].start; high = pool_parts[part].end; }
    for (size_t i = 0; i < pool_free_count;) {
        if (pool_free[i].start < low || pool_free[i].end > high) { i++; continue; }
        if (pool_free[i].end == start) { start = pool_free[i].start; pool_free[i] = pool_free[--pool_free_count]; i = 0; continue; }
        if (pool_free[i].start == end) { end = pool_free[i].end; pool_free[i] = pool_free[--pool_free_count]; i = 0; continue; }
        i++;
    }
    if (pool_free_count < GP_POOL_RANGES) { pool_free[pool_free_count].start = start; pool_free[pool_free_count].end = end; pool_free_count++; }
    layout->pool_start = layout->pool_end = layout->pool_alias = 0;
    pthread_mutex_unlock(&pool_lock);
}

// --- Environment rules -------------------------------------------------------

void gp_set_large_reserve(uintptr_t start, uintptr_t end) {
    if (end > start) snprintf(large_reserve, sizeof large_reserve, "%#lx-%#lx", (unsigned long)start, (unsigned long)end);
}
void gp_set_environment_rules(const char *rules) {
    snprintf(environment_rules, sizeof environment_rules, "%s", rules ? rules : "");
}
static void command_line(int argc, char *const argv[], char *command, size_t size) {
    size_t used = 0;
    command[0] = 0;
    for (int i = 0; i < argc && argv[i] && used < size; i++)
        used += (size_t)snprintf(command + used, size - used, "%s%s", i ? " " : "", argv[i]);
}
static bool set_entry(GPSlot *s, const char *name, char *entry);
void gp_apply_environment_rules(size_t slot, int argc, char *const argv[]) {
    // This is a host allocation policy for an explicitly selected process,
    // not an inheritable guest setting. Helpers must not silently consume
    // fresh ranges reserved for later game launches.
    if (slot) gp_setenv(slot,"TOLKARA_PROCESS_RANGE_POOL","",1);
    char command[2048];
    command_line(argc, argv, command, sizeof command);
    for (const char *rule = environment_rules; *rule;) {
        const char *end = strchr(rule, ';'), *arrow;
        if (!end) end = rule + strlen(rule);
        arrow = memchr(rule, '>', (size_t)(end - rule));
        size_t length = arrow ? (size_t)(arrow - rule) : 0;
        if (arrow && ((length == 1 && *rule == '*') || (length && contains_ignoring_case(command, rule, length)))) {
            char assignments[512], expanded[640];
            snprintf(assignments, sizeof assignments, "%.*s", (int)(end - arrow - 1), arrow + 1);
            // ${LargeReserve} stands for the range reserved at startup.
            const char *mark = strstr(assignments, "${LargeReserve}");
            if (mark) {
                snprintf(expanded, sizeof expanded, "%.*s%s%s", (int)(mark - assignments), assignments, large_reserve, mark + 15);
                snprintf(assignments, sizeof assignments, "%s", expanded);
            }
            for (char *save = NULL, *entry = strtok_r(assignments, " ", &save); entry; entry = strtok_r(NULL, " ", &save)) {
                char *equals = strchr(entry, '=');
                if (!equals || equals == entry) continue;
                *equals = 0;
                if (!slot) setenv(entry, equals + 1, 1);
                else {
                    char *copy = NULL;
                    *equals = '=';
                    copy = strdup(entry);
                    *equals = 0;
                    if (copy) {
                        pthread_mutex_lock(&slots[slot].lock);
                        set_entry(&slots[slot], entry, copy);
                        pthread_mutex_unlock(&slots[slot].lock);
                    }
                }
                LOG("[processes] slot %zu: %s=%s for %.80s\n", slot, entry, equals + 1, command);
            }
            return;
        }
        rule = *end ? end + 1 : end;
    }
}

// --- The environment -------------------------------------------------------

static bool valid_name(const char *name) { return name && *name && !strchr(name, '='); }
// The entry for name in a slot's environment, its index in *index. Locked.
static char *find_entry(GPSlot *s, const char *name, size_t *index) {
    size_t length = strlen(name);
    for (size_t i = 0; i < s->environment_count; i++)
        if (!strncmp(s->environment[i], name, length) && s->environment[i][length] == '=') {
            if (index) *index = i;
            return s->environment[i];
        }
    return NULL;
}
// Replaced and removed strings are kept: a getenv result may still point there.
static bool set_entry(GPSlot *s, const char *name, char *entry) {
    size_t index;
    if (find_entry(s, name, &index)) { s->environment[index] = entry; return true; }
    char **grown = realloc(s->environment, (s->environment_count + 2) * sizeof *grown);
    if (!grown) return false;
    s->environment = grown;
    s->environment[s->environment_count++] = entry;
    s->environment[s->environment_count] = NULL;
    return true;
}
char *gp_getenv(size_t slot, const char *name) {
    if (!slot || slot >= slot_count) return getenv(name);
    if (!valid_name(name)) return NULL;
    GPSlot *s = &slots[slot];
    pthread_mutex_lock(&s->lock);
    char *entry = find_entry(s, name, NULL);
    pthread_mutex_unlock(&s->lock);
    return entry ? entry + strlen(name) + 1 : NULL;
}
int gp_setenv(size_t slot, const char *name, const char *value, int overwrite) {
    if (!slot || slot >= slot_count) return setenv(name, value, overwrite);
    if (!valid_name(name) || !value) { errno = EINVAL; return -1; }
    GPSlot *s = &slots[slot];
    pthread_mutex_lock(&s->lock);
    int result = 0;
    if (overwrite || !find_entry(s, name, NULL)) {
        char *entry = NULL;
        if (asprintf(&entry, "%s=%s", name, value) < 0 || !set_entry(s, name, entry)) {
            free(entry); errno = ENOMEM; result = -1;
        }
    }
    pthread_mutex_unlock(&s->lock);
    return result;
}
int gp_unsetenv(size_t slot, const char *name) {
    if (!slot || slot >= slot_count) return unsetenv(name);
    if (!valid_name(name)) { errno = EINVAL; return -1; }
    GPSlot *s = &slots[slot];
    pthread_mutex_lock(&s->lock);
    size_t index;
    while (find_entry(s, name, &index)) {
        memmove(&s->environment[index], &s->environment[index + 1], (s->environment_count - index) * sizeof *s->environment);
        s->environment_count--;
    }
    pthread_mutex_unlock(&s->lock);
    return 0;
}
int gp_putenv(size_t slot, char *entry) {
    if (!slot || slot >= slot_count) return putenv(entry);
    const char *equals = entry ? strchr(entry, '=') : NULL;
    if (!equals || equals == entry) { errno = EINVAL; return -1; }
    char name[256];
    size_t length = (size_t)(equals - entry);
    if (length >= sizeof name) { errno = EINVAL; return -1; }
    memcpy(name, entry, length); name[length] = 0;
    GPSlot *s = &slots[slot];
    pthread_mutex_lock(&s->lock);
    bool ok = set_entry(s, name, entry);
    pthread_mutex_unlock(&s->lock);
    if (!ok) { errno = ENOMEM; return -1; }
    return 0;
}
char ***gp_environ(size_t slot) {
    if (!slot || slot >= slot_count) return _NSGetEnviron();
    return &slots[slot].environment;
}

// --- Threads ---------------------------------------------------------------

// Keep our own thread-port right until the kernel reports death. TLS cleanup
// (and even pthread_join) can precede the final native stack teardown. This is
// lifetime metadata only; no thread state or guest memory is inspected.
static void register_native_thread(size_t slot) {
    GPThreadRecord *record = malloc(sizeof *record);
    mach_port_t port = mach_thread_self();
    GPSlot *s = &slots[slot];
    pthread_mutex_lock(&s->threads_lock);
    if (!record || !MACH_PORT_VALID(port)) {
        s->thread_tracking_failed = true;
        free(record);
        if (MACH_PORT_VALID(port)) mach_port_deallocate(mach_task_self(), port);
    } else {
        record->port = port;
        record->next = s->threads;
        s->threads = record;
    }
    pthread_mutex_unlock(&s->threads_lock);
}
bool gp_threads_terminated(size_t slot) {
    if (slot >= slot_count) return false;
    GPSlot *s = &slots[slot];
    if (atomic_load(&s->threads_state) != GP_THREADS_EXITED) return false;
    pthread_mutex_lock(&s->threads_lock);
    bool terminated = s->threads && !atomic_load(&s->thread_tracking_failed);
    for (GPThreadRecord *record = s->threads; record && terminated; record = record->next) {
        if (record->port == MACH_PORT_NULL) continue;
        mach_port_type_t type = 0;
        if (mach_port_type(mach_task_self(), record->port, &type) != KERN_SUCCESS ||
            !(type & MACH_PORT_TYPE_DEAD_NAME)) terminated = false;
        else {
            mach_port_deallocate(mach_task_self(), record->port);
            record->port = MACH_PORT_NULL;
        }
    }
    pthread_mutex_unlock(&s->threads_lock);
    return terminated;
}

typedef struct { void *(*start)(void *); void *argument; size_t slot; } GPThreadStart;
static void *tagged_thread(void *context) {
    GPThreadStart start = *(GPThreadStart *)context;
    free(context);
    register_native_thread(start.slot);
    pthread_setspecific(slot_key, (void *)(uintptr_t)(start.slot + 1));
    return start.start(start.argument);
}
int gp_pthread_create(size_t slot, pthread_t *thread, const pthread_attr_t *attributes,
                      void *(*start)(void *), void *argument) {
    if (slot_count < 2) return pthread_create(thread, attributes, start, argument);
    if (slot >= slot_count) return EINVAL;
    GPThreadStart *context = malloc(sizeof *context);
    if (!context) return EAGAIN;
    *context = (GPThreadStart){start, argument, slot};
    uint_fast64_t state = atomic_load(&slots[slot].threads_state);
    do {
        if (state & GP_THREADS_EXITED) { free(context); return EAGAIN; }
    } while (!atomic_compare_exchange_weak(&slots[slot].threads_state, &state, state + 1));
    int result = pthread_create(thread, attributes, tagged_thread, context);
    if (result) {
        atomic_fetch_sub(&slots[slot].threads_state, 1);
        free(context);
    }
    return result;
}

// --- Signals ---------------------------------------------------------------

static pthread_mutex_t signal_lock = PTHREAD_MUTEX_INITIALIZER;
static struct sigaction slot_actions[GP_MAX_PROCESSES][NSIG];
static bool slot_has_action[GP_MAX_PROCESSES][NSIG];
static struct sigaction host_previous[NSIG];
static bool dispatching[NSIG];

static void dispatch(int number, siginfo_t *info, void *context) {
    if (gsv_handle_signal(number, info, context)) return;
    ucontext_t *uc = context;
    uintptr_t pc = uc ? (uintptr_t)arm_thread_state64_get_pc(uc->uc_mcontext->__ss) : 0;
    size_t slot = gp_current_slot(pc);
    const struct sigaction *action = slot_has_action[slot][number] ? &slot_actions[slot][number] : &host_previous[number];
    if (action->sa_flags & SA_SIGINFO) {
        if (action->sa_sigaction) { action->sa_sigaction(number, info, context); return; }
    }
    else if (action->sa_handler == SIG_IGN) return;
    else if (action->sa_handler != SIG_DFL) { action->sa_handler(number); return; }
    // Nobody handles it: what the kernel does by default, once the fault repeats.
    struct sigaction fallback = {0};
    fallback.sa_handler = SIG_DFL;
    sigaction(number, &fallback, NULL);
}
int gp_sigaction(size_t slot, int number, const struct sigaction *action, struct sigaction *old) {
    if (slot_count < 2 || number == SIGKILL || number == SIGSTOP) return sigaction(number, action, old);
    if (number <= 0 || number >= NSIG || slot >= slot_count) { errno = EINVAL; return -1; }
    pthread_mutex_lock(&signal_lock);
    struct sigaction previous = {0};
    if (slot_has_action[slot][number]) previous = slot_actions[slot][number];
    else if (!slot && !dispatching[number]) sigaction(number, NULL, &previous);
    else if (!slot) previous = host_previous[number];
    else previous.sa_handler = SIG_DFL;
    int result = 0;
    if (action) {
        if (!dispatching[number]) {
            struct sigaction installed = *action;
            installed.sa_sigaction = dispatch;
            installed.sa_flags |= SA_SIGINFO;
            result = sigaction(number, &installed, &host_previous[number]);
            if (!result) dispatching[number] = true;
        }
        if (!result) { slot_actions[slot][number] = *action; slot_has_action[slot][number] = true; }
    }
    pthread_mutex_unlock(&signal_lock);
    if (!result && old) *old = previous;
    return result;
}

// --- Address ranges ----------------------------------------------------------

// A process given its own address range (WINELARGERESERVE) owns it while it runs; when it
// exits the range is reserved afresh, so a later process given the same range finds it
// empty (a short-lived one such as SteamService.exe, then a game). Two live processes
// never share one.
static pthread_mutex_t range_lock = PTHREAD_MUTEX_INITIALIZER;
static uintptr_t range_start[GP_MAX_PROCESSES], range_end[GP_MAX_PROCESSES];
static bool slot_range(size_t slot, uintptr_t *start, uintptr_t *end) {
    const char *range = gp_getenv(slot, "WINELARGERESERVE");
    unsigned long long a = 0, b = 0;
    if (!range || sscanf(range, "%llx-%llx", &a, &b) != 2 || b <= a) return false;
    *start = (uintptr_t)a; *end = (uintptr_t)b;
    return true;
}
static bool claim_range(size_t slot) {
    uintptr_t start, end;
    if (!slot_range(slot, &start, &end)) return true;
    // Opt-in fresh ranges for successive games. Only partition the reservation
    // already owned by the host; retired process ranges remain unavailable.
    const char *range_pool=gp_getenv(slot,"TOLKARA_PROCESS_RANGE_POOL");
    if (range_pool && *range_pool) {
        unsigned long long first=0,last=0,host_first=0,host_last=0;
        char trailing;
        if (sscanf(range_pool,"%llx-%llx%c",&first,&last,&trailing)!=2 ||
            sscanf(large_reserve,"%llx-%llx",&host_first,&host_last)!=2 ||
            first<host_first || last>host_last || last<=first ||
            (first & 0xffff) || (last & 0xffff) || end-start>last-first) return false;
        uintptr_t length=end-start;
        pthread_mutex_lock(&range_lock);
        bool found=false;
        for (uintptr_t candidate=(uintptr_t)first; candidate<=(uintptr_t)last-length; candidate+=length) {
            bool overlap=false;
            for (size_t i=1;i<GP_MAX_PROCESSES;i++)
                if (i!=slot && range_end[i]>candidate && range_start[i]<candidate+length) { overlap=true; break; }
            if (!overlap) { start=candidate; end=candidate+length; found=true; break; }
        }
        if (!found) { pthread_mutex_unlock(&range_lock); return false; }
        char selected[64];
        snprintf(selected,sizeof selected,"%#lx-%#lx",(unsigned long)start,(unsigned long)end);
        if (gp_setenv(slot,"WINELARGERESERVE",selected,1) || gp_setenv(slot,"WINESMALLRANGE",selected,1)) {
            pthread_mutex_unlock(&range_lock); return false;
        }
        range_start[slot]=start; range_end[slot]=end;
        pthread_mutex_unlock(&range_lock);
        LOG("[processes] slot %zu: fresh private range %s\n",slot,selected);
        return true;
    }
    pthread_mutex_lock(&range_lock);
    for (size_t i = 1; i < GP_MAX_PROCESSES; i++)
        if (i != slot && range_end[i] > start && range_start[i] < end) {
            pthread_mutex_unlock(&range_lock);
            LOG("[processes] slot %zu: range %#lx-%#lx is still slot %zu's\n", slot, (unsigned long)start,
                (unsigned long)end, i);
            return false;
        }
    range_start[slot] = start; range_end[slot] = end;
    pthread_mutex_unlock(&range_lock);
    return true;
}
static void release_range(size_t slot) {
    pthread_mutex_lock(&range_lock);
    uintptr_t start = range_start[slot], end = range_end[slot];
    if (end <= start) { pthread_mutex_unlock(&range_lock); return; }
    // Keep ownership until replacement completes. Otherwise a concurrent
    // spawn can claim and populate the range before this MAP_FIXED erases it.
    void *fresh = mmap((void *)start, end - start, PROT_NONE, MAP_FIXED | MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
    if (fresh == (void *)start) range_start[slot] = range_end[slot] = 0;
    pthread_mutex_unlock(&range_lock);
    LOG("[processes] slot %zu: range %#lx-%#lx %s\n", slot, (unsigned long)start, (unsigned long)end,
        fresh == (void *)start ? "reserved afresh" : "reset failed; ownership retained");
}

static bool (*retirement_check)(size_t);
void gp_set_retirement_check(bool (*check)(size_t)) { retirement_check=check; }
bool gp_reclaim_range(size_t slot) {
    if (!slot || slot >= slot_count || !retirement_check ||
        !gp_threads_terminated(slot) || !retirement_check(slot)) return false;
    release_range(slot);
    pthread_mutex_lock(&range_lock);
    bool released=range_end[slot] <= range_start[slot];
    pthread_mutex_unlock(&range_lock);
    return released;
}

// --- Starting and ending a slot ---------------------------------------------

typedef struct { size_t slot; int argc; char **argv; } GPSpawn;
static void *slot_main(void *context) {
    GPSpawn spawn = *(GPSpawn *)context;
    free(context);
    register_native_thread(spawn.slot);
    pthread_setspecific(slot_key, (void *)(uintptr_t)(spawn.slot + 1));
    LOG("[processes] slot %zu starts %s\n", spawn.slot, spawn.argc > 1 ? spawn.argv[1] : spawn.argv[0]);
    start_slot(spawn.slot, spawn.argc, spawn.argv);
    gp_slot_exit(spawn.slot, 0);
}
int gp_spawn(char *const argv[], char *const envp[]) {
    if (slot_count < 2 || !start_slot || !argv || !argv[0]) return ENOTSUP;
    for (size_t i = 1; i < slot_count; i++)
        if (atomic_load(&slots[i].threads_state) & GP_THREADS_EXITED)
            LOG("[processes] slot %zu: native threads %s; callback/data retirement still required\n",
                i, gp_threads_terminated(i) ? "terminated" : "not yet confirmed terminated");
    if (retirement_check)
        for (size_t i=1; i<slot_count; i++) gp_reclaim_range(i);
    size_t slot = 0;
    for (size_t i = 1; i < slot_count && !slot; i++) {
        bool expected = false;
        if (atomic_compare_exchange_strong(&slots[i].started, &expected, true)) slot = i;
    }
    if (!slot) { LOG("[processes] no free slot for %s\n", argv[1] ? argv[1] : argv[0]); return EAGAIN; }
    GPSlot *s = &slots[slot];
    if (pool_rules[0] || pool_free_count) {
        size_t argc = 0;
        while (argv[argc]) argc++;
        // argv[0] is the runtime's own executable; the program follows.
        if (!gp_take_pool(slot, (int)argc - 1, argv + 1)) { atomic_store(&s->started, false); return ENOMEM; }
    }
    // Its own copy of the environment, with its own share of the code pool.
    size_t count = 0;
    while (envp && envp[count]) count++;
    s->environment = calloc(count + 2, sizeof *s->environment);
    for (size_t i = 0; i < count; i++) s->environment[i] = strdup(envp[i]);
    s->environment_count = count;
    if (s->layout.pool_end > s->layout.pool_start) {
        char *pool = NULL;
        if (asprintf(&pool, "WINEJITPOOL=%#lx-%#lx@%#lx", (unsigned long)s->layout.pool_start,
                     (unsigned long)s->layout.pool_end, (unsigned long)s->layout.pool_alias) > 0)
            set_entry(s, "WINEJITPOOL", pool);
    }
    {
        size_t argc = 0;
        while (argv[argc]) argc++;
        gp_apply_environment_rules(slot, (int)argc - 1, argv + 1);
    }
    if (!claim_range(slot)) { give_back_pool(slot); atomic_store(&s->started, false); return EAGAIN; }
    GPSpawn *spawn = calloc(1, sizeof *spawn);
    size_t argc = 0;
    while (argv[argc]) argc++;
    spawn->slot = slot; spawn->argc = (int)argc;
    spawn->argv = calloc(argc + 1, sizeof *spawn->argv);
    for (size_t i = 0; i < argc; i++) spawn->argv[i] = strdup(argv[i]);
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setstacksize(&attributes, 8u << 20);
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    atomic_fetch_add(&s->threads_state, 1);
    int result = pthread_create(&thread, &attributes, slot_main, spawn);
    if (result) atomic_fetch_sub(&s->threads_state, 1);
    pthread_attr_destroy(&attributes);
    if (result) { LOG("[processes] slot %zu thread failed: %d\n", slot, result); atomic_store(&s->started, false); free(spawn); }
    return result;
}
static void (*process_exit_callback)(size_t);
void gp_set_exit_callback(void (*callback)(size_t)) { process_exit_callback=callback; }
void gp_slot_exit(size_t slot, int code) {
    if (slot_count < 2 || (uintptr_t)pthread_getspecific(slot_key) != slot + 1)
        atomic_store(&slots[slot].thread_tracking_failed, true);
    atomic_fetch_or(&slots[slot].threads_state, GP_THREADS_EXITED);
    LOG("[processes] slot %zu: process exit with %zu tracked threads still live\n",
        slot, live_threads(slot));
    if (process_exit_callback) process_exit_callback(slot);
    LOG("[processes] slot %zu exits with %d; its thread ends, the app stays\n", slot, code);
    // Prepared code pages are single-use across process lifetimes. Builtin data
    // sections may have permanently lost execute permission, and late threads
    // may still refer to this pool. Keep it owned by the retired slot; handing
    // it to another process can turn its JIT code into execute faults.
    // Failed spawns before entry may still return their untouched pool.
    // A Wine thread may exit while still using a stack in this reservation.
    // Remapping it here destroys our own call frames before pthread_exit can
    // finish. Keep the reservation claimed in that case. A future reaper may
    // release the reservation after all slot threads end; the prepared pool
    // remains retired for this app session regardless of thread lifetime.
    uintptr_t stack_marker = (uintptr_t)&stack_marker;
    pthread_mutex_lock(&range_lock);
    bool stack_in_range = stack_marker >= range_start[slot] && stack_marker < range_end[slot];
    pthread_mutex_unlock(&range_lock);
    bool tracked_current = slot_count > 1 &&
        (uintptr_t)pthread_getspecific(slot_key) == slot + 1;
    bool live_peers = live_threads(slot) > (tracked_current ? 1u : 0u);
    if (retirement_check || stack_in_range || live_peers) {
        LOG("[processes] slot %zu: retaining range and code pool pending lifetime retirement\n", slot);
    } else {
        LOG("[processes] slot %zu: retiring its prepared code pool until app exit\n", slot);
        release_range(slot);
    }
    pthread_exit((void *)(intptr_t)code);
}
