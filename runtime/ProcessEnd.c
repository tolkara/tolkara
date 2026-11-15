#include "ProcessEnd.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>

static atomic_uint_fast64_t deadline;   // CLOCK_MONOTONIC nanoseconds
static atomic_int end_code;
static atomic_flag started = ATOMIC_FLAG_INIT;

static uint64_t now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}
static void *watch(void *unused) {
    (void)unused;
    while (now() < atomic_load(&deadline)) usleep(20000);
    // Async-signal-safe on purpose: stdio's locks may be what is stuck.
    static const char note[] = "[native] exit did not finish in time; ending the process\n";
    (void)!write(STDERR_FILENO, note, sizeof note - 1);
    _exit(atomic_load(&end_code));
    return NULL;
}
void pe_deadline(int code, double seconds) {
    if (!(seconds > 0)) seconds = 0;
    if (seconds > 600) seconds = 600;
    atomic_store(&end_code, code);
    atomic_store(&deadline, now() + (uint64_t)(seconds * 1e9));
    if (atomic_flag_test_and_set(&started)) return;
    pthread_t thread;
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    // No thread: exit as before, unbounded.
    if (pthread_create(&thread, &attributes, watch, NULL)) atomic_flag_clear(&started);
    pthread_attr_destroy(&attributes);
}
