// Host-only lifetime accounting; no guest image or memory is inspected.
#include "../runtime/GuestProcesses.c"
#include <assert.h>
const GuestLibrary *gl_library_at(const GuestLinkSet *s, uint64_t a) { (void)s; (void)a; return NULL; }
bool gsv_handle_signal(int n, siginfo_t *i, void *c) { (void)n; (void)i; (void)c; return false; }
static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER;
static void *exit_worker(void *arg) { (void)arg; gp_slot_exit(1, 73); }
static void *worker(void *arg) {
    assert(gp_current_slot(0) == 1);
    pthread_mutex_lock(&gate);
    pthread_mutex_unlock(&gate);
    if (arg) pthread_exit(arg);
    return NULL;
}
int main(void) {
    gp_configure(3, stderr, NULL);
    pthread_t threads[2];
    pthread_mutex_lock(&gate);
    assert(!gp_pthread_create(1, &threads[0], NULL, worker, NULL));
    assert(!gp_pthread_create(1, &threads[1], NULL, worker, (void *)1));
    assert(live_threads(1) == 2);
    size_t size = (size_t)getpagesize();
    void *region = mmap(NULL, size, PROT_READ|PROT_WRITE, MAP_ANON|MAP_PRIVATE, -1, 0);
    assert(region != MAP_FAILED);
    range_start[1] = (uintptr_t)region; range_end[1] = (uintptr_t)region + size;
    *(int *)region = 42;
    pthread_t exiting;
    assert(!gp_pthread_create(1, &exiting, NULL, exit_worker, NULL));
    assert(!pthread_join(exiting, NULL));
    assert(range_start[1] == (uintptr_t)region && *(int *)region == 42);
    assert(live_threads(1) == 2);
    pthread_mutex_unlock(&gate);
    void *result;
    assert(!pthread_join(threads[0], &result) && result == NULL);
    assert(!pthread_join(threads[1], &result) && result == (void *)1);
    assert(live_threads(1) == 0);
    assert(gp_pthread_create(1, &threads[0], NULL, worker, NULL) == EAGAIN);
    assert(live_threads(1) == 0);
    assert(gp_pthread_create(3, &threads[0], NULL, worker, NULL) == EINVAL);
    assert(!munmap(region, size));
    puts("PASS: return and pthread_exit retire their tracked thread exactly once");
}
