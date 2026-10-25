// Standalone internal lifecycle fixture: no guest application is loaded.
// Build: clang -Wall -Wextra -Werror -pthread tests/test_guest_process_exit.c -o /tmp/test_guest_process_exit
// Run both with no arguments and with stack-in-range.
#include "../runtime/GuestProcesses.c"
#include <assert.h>
#include <sys/resource.h>
const GuestLibrary *gl_library_at(const GuestLinkSet *s, uint64_t a) { (void)s; (void)a; return NULL; }
bool gsv_handle_signal(int n, siginfo_t *i, void *c) { (void)n; (void)i; (void)c; return false; }
static size_t exited_slot;
static void exit_notice(size_t slot) { exited_slot=slot; }
static void *worker(void *unused) { (void)unused; gp_slot_exit(1, 73); }
int main(int argc, char **argv) {
    (void)argv;
    struct rlimit no_core = {0,0}; setrlimit(RLIMIT_CORE, &no_core);
    size_t size = 8u << 20;
    void *region = mmap(NULL,size,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0);
    assert(region != MAP_FAILED);
    gp_configure(3, stderr, NULL);
    gp_set_exit_callback(exit_notice);
    const uintptr_t code_base = 0x100000000ULL;
    gp_set_pool(code_base, code_base + (4u << 20), code_base + (8u << 20), "*=1");
    char *command[] = {"owned-probe", NULL};
    assert(gp_take_pool(1, 1, command));
    uintptr_t retired_start = slots[1].layout.pool_start;
    uintptr_t retired_end = slots[1].layout.pool_end;
    range_start[1]=(uintptr_t)region; range_end[1]=(uintptr_t)region+size;
    pthread_attr_t attr; assert(!pthread_attr_init(&attr));
    if(argc>1) { assert(!pthread_attr_setguardsize(&attr,0)); assert(!pthread_attr_setstack(&attr,region,size)); }
    pthread_t thread; assert(!pthread_create(&thread,&attr,worker,NULL));
    void *result=NULL; assert(!pthread_join(thread,&result)); assert((intptr_t)result==73);
    assert(exited_slot==1);
    if (argc > 1) {
        assert(range_start[1] == (uintptr_t)region);
        assert(range_end[1] == (uintptr_t)region + size);
    } else {
        assert(range_start[1] == 0 && range_end[1] == 0);
    }
    assert(slots[1].layout.pool_start == retired_start);
    assert(slots[1].layout.pool_end == retired_end);
    assert(gp_take_pool(2, 1, command));
    assert(slots[2].layout.pool_start >= retired_end);
    // A pre-entry rollback has not used the pages and must remain reusable.
    uintptr_t unused_start = slots[2].layout.pool_start;
    give_back_pool(2);
    assert(gp_take_pool(2, 1, command));
    assert(slots[2].layout.pool_start == unused_start);
    assert(!munmap(region, size));
    puts("PASS: host survived slot exit with correct reservation ownership"); return 0;
}
