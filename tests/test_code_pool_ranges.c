// A code pool in two ranges (the low address space had no single gap for
// it): a share lies in one range, has that range's writable view, and goes
// back only to its own range. Addresses are only compared; nothing is mapped.
#include "../runtime/GuestProcesses.c"
#include <assert.h>
const GuestLibrary *gl_library_at(const GuestLinkSet *s, uint64_t a) { (void)s; (void)a; return NULL; }
bool gsv_handle_signal(int n, siginfo_t *i, void *c) { (void)n; (void)i; (void)c; return false; }
int main(void) {
    const uintptr_t mib = 1u << 20, a = 0x100000000ULL, b = 0x140000000ULL, view_a = 0x7000000000ULL, view_b = 0x7100000000ULL;
    gp_configure(4, stderr, NULL);
    assert(!gp_add_pool(b, b + 4 * mib, view_b));                       // no pool yet
    gp_set_pool(a, a + 5 * mib, view_a, "big=4;small=2;huge=6");
    assert(!gp_add_pool(a + 4 * mib, a + 8 * mib, view_b));             // overlaps the first range
    assert(gp_add_pool(b, b + 4 * mib, view_b));
    char *big[] = {"big", NULL}, *small[] = {"small", NULL}, *huge[] = {"huge", NULL};
    // 4 MiB fit the first range; the next 4 do not (1 MiB is left) and take the second.
    assert(gp_take_pool(0, 1, big));
    assert(slots[0].layout.pool_start == a && slots[0].layout.pool_end == a + 4 * mib && slots[0].layout.pool_alias == view_a);
    assert(gp_take_pool(1, 1, big));
    assert(slots[1].layout.pool_start == b && slots[1].layout.pool_end == b + 4 * mib && slots[1].layout.pool_alias == view_b);
    // 9 MiB in all, but no range holds 6: never one share across both.
    assert(!gp_take_pool(2, 1, huge));
    assert(!gp_take_pool(2, 1, small));
    give_back_pool(1);
    assert(gp_take_pool(2, 1, small));
    assert(slots[2].layout.pool_start >= b && slots[2].layout.pool_end <= b + 4 * mib);
    assert(slots[2].layout.pool_alias == view_b + (slots[2].layout.pool_start - b));

    // Two ranges that touch keep their own views, also after shares come back.
    gp_set_pool(a, a + 4 * mib, view_a, "big=4;small=2;huge=6");
    for (size_t i = 0; i < 4; i++) slots[i].layout = (GPSlotLayout){0};
    assert(gp_add_pool(a + 4 * mib, a + 8 * mib, view_b));
    assert(gp_take_pool(0, 1, big) && gp_take_pool(1, 1, big));
    assert(slots[1].layout.pool_start == a + 4 * mib && slots[1].layout.pool_alias == view_b);
    give_back_pool(0); give_back_pool(1);
    assert(!gp_take_pool(2, 1, huge));
    assert(gp_take_pool(2, 1, small) && gp_take_pool(3, 1, big));
    assert((slots[3].layout.pool_start == a && slots[3].layout.pool_alias == view_a) ||
           (slots[3].layout.pool_start == a + 4 * mib && slots[3].layout.pool_alias == view_b));
    puts("PASS: a code pool in two ranges keeps each share and its view inside one range");
}
