// Kernel lifetime of our own synthetic thread; no guest image is loaded.
#include "../runtime/GuestProcesses.c"
#include <assert.h>
const GuestLibrary *gl_library_at(const GuestLinkSet *s, uint64_t a) { (void)s; (void)a; return NULL; }
bool gsv_handle_signal(int n, siginfo_t *i, void *c) { (void)n; (void)i; (void)c; return false; }
static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static bool cleaning, finish;
static bool callbacks_retired;
static bool retired(size_t slot) { return slot==1 && callbacks_retired; }
static pthread_key_t final_key;
static void delayed_cleanup(void *value) {
    (void)value;
    // Model the interval after our TLS destructor but before native teardown,
    // independent of the implementation's ordering of pthread-key destructors.
    void *tag = pthread_getspecific(slot_key);
    if (tag) { pthread_setspecific(slot_key, NULL); thread_finished(tag); }
    pthread_mutex_lock(&gate);
    cleaning = true;
    pthread_cond_broadcast(&changed);
    while (!finish) pthread_cond_wait(&changed, &gate);
    pthread_mutex_unlock(&gate);
}
static void *worker(void *value) {
    (void)value;
    assert(!pthread_setspecific(final_key, (void *)1));
    gp_slot_exit(1, 0);
}
int main(void) {
    gp_configure(2, stderr, NULL);
    size_t length=(size_t)getpagesize();
    void *range=mmap(NULL,length,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    assert(range!=MAP_FAILED);
    memset(range,0x5a,length);
    range_start[1]=(uintptr_t)range; range_end[1]=(uintptr_t)range+length;
    gp_set_retirement_check(retired);
    assert(!gp_reclaim_range(0) && !gp_reclaim_range(2));
    assert(!pthread_key_create(&final_key, delayed_cleanup));
    assert(!gp_threads_terminated(1));
    pthread_t thread;
    assert(!gp_pthread_create(1, &thread, NULL, worker, NULL));
    pthread_mutex_lock(&gate);
    while (!cleaning) pthread_cond_wait(&changed, &gate);
    assert(live_threads(1) == 0);
    assert(!gp_threads_terminated(1));
    callbacks_retired=true;
    assert(!gp_reclaim_range(1)); // TLS count zero, native teardown not complete
    assert(*(unsigned char *)range==0x5a);
    callbacks_retired=false;
    finish = true;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&gate);
    assert(!pthread_join(thread, NULL));
    for (unsigned n = 0; n < 1000 && !gp_threads_terminated(1); n++) usleep(1000);
    assert(gp_threads_terminated(1));
    assert(gp_threads_terminated(1)); // releasing dead-name rights is idempotent
    assert(!gp_threads_terminated(2));
    assert(!gp_reclaim_range(1)); // native death alone is insufficient
    assert(*(unsigned char *)range==0x5a);
    callbacks_retired=true;
    assert(gp_reclaim_range(1));
    assert(!range_start[1] && !range_end[1]);
    assert(gp_reclaim_range(1)); // idempotent; prepared code is never reused
    munmap(range,length);
    slots[1].thread_tracking_failed = true;
    assert(!gp_threads_terminated(1)); // missing ownership information fails closed
    puts("PASS: TLS count zero does not authorize native thread reclamation");
}
