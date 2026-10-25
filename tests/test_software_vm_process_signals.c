#include "GuestSoftwareVM.h"
#include "GuestProcesses.h"
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <sys/mman.h>

// This fixture loads no images: thread tags select the actual process router.
const GuestLibrary *gl_library_at(const GuestLinkSet *set, uint64_t address) {
    (void)set; (void)address; return NULL;
}
extern uint64_t gm_sparse_probe_program(void *, uint64_t, void *);
static volatile sig_atomic_t delivered[2];
static void first(int number) { assert(number == SIGSEGV); ++delivered[0]; }
static void second(int number) { assert(number == SIGSEGV); ++delivered[1]; }
static void *worker(void *memory) {
    uint64_t output[4];
    errno = EDOM;
    assert(gm_sparse_probe_program(memory, 7, output) == 49);
    assert(errno == EDOM);
    for (unsigned i = 0; i < 4; ++i) assert(output[i] == 7);
    assert(!raise(SIGSEGV));
    return NULL;
}
int main(void) {
    assert(gsv_start(16 * GM_PAGE_SIZE, 1, -1));
    gp_configure(2, NULL, NULL);
    struct sigaction action = {0};
    sigemptyset(&action.sa_mask); action.sa_handler = first;
    assert(!gp_sigaction(0, SIGSEGV, &action, NULL));
    action.sa_handler = second;
    assert(!gp_sigaction(1, SIGSEGV, &action, NULL));
    void *memory = gsv_map(NULL, 2 * GM_PAGE_SIZE, PROT_READ | PROT_WRITE,
                          MAP_ANON | MAP_PRIVATE, -1, 0);
    assert(memory != MAP_FAILED && gsv_address(memory));
    pthread_t thread;
    for (size_t slot = 0; slot < 2; ++slot) {
        assert(!gp_pthread_create(slot, &thread, NULL, worker,
                                 (char *)memory + slot * GM_PAGE_SIZE));
        assert(!pthread_join(thread, NULL));
    }
    assert(delivered[0] == 1 && delivered[1] == 1);
    assert(gsv_fault_count() > 0);
    assert(!gsv_unmap(memory, 2 * GM_PAGE_SIZE));
    gsv_stop();
    puts("PASS: software faults resolved before per-process signal delivery");
    return 0;
}
