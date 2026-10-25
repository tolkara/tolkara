// Exercise failed range reset and concurrent claiming without loading a guest.
#include <sys/mman.h>
static void *reset_mmap(void *, size_t, int, int, int, off_t);
#define mmap reset_mmap
#include "../runtime/GuestProcesses.c"
#undef mmap
#include <assert.h>

const GuestLibrary *gl_library_at(const GuestLinkSet *s, uint64_t a) { (void)s; (void)a; return NULL; }
bool gsv_handle_signal(int n, siginfo_t *i, void *c) { (void)n; (void)i; (void)c; return false; }
static bool fail_reset;
static void *reset_mmap(void *address, size_t size, int prot, int flags, int fd, off_t offset) {
    // A reset must serialize with claim_range until the native mapping exists.
    int locked = pthread_mutex_trylock(&range_lock);
    if (!locked) pthread_mutex_unlock(&range_lock);
    assert(locked == EBUSY);
    assert(range_start[1] == (uintptr_t)address);
    if (fail_reset) { errno = ENOMEM; return MAP_FAILED; }
    return mmap(address, size, prot, flags, fd, offset);
}
int main(void) {
    gp_configure(3, stderr, NULL);
    size_t size = (size_t)getpagesize();
    void *region = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    assert(region != MAP_FAILED);
    *(int *)region = 42;
    range_start[1] = (uintptr_t)region; range_end[1] = (uintptr_t)region + size;
    char bounds[80];
    snprintf(bounds, sizeof bounds, "%lx-%lx", (unsigned long)region, (unsigned long)region + size);
    assert(!gp_setenv(2, "WINELARGERESERVE", bounds, 1));
    fail_reset = true;
    release_range(1);
    assert(!claim_range(2));
    assert(*(int *)region == 42);
    fail_reset = false;
    release_range(1);
    assert(claim_range(2));
    assert(range_start[1] == 0 && range_end[1] == 0);
    assert(!munmap(region, size));
    puts("PASS: reset failure retains ownership; only a completed reset allows reuse");
}
