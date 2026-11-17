// Own mappings only: verify the low-address tail cannot be stolen by an alias
// between the two executable allocations of one preparation transaction.
#include "../runtime/NativeCodeMemory.c"
#include <assert.h>

static NCPreparation reject_pair(void *first, size_t first_size,
                                void *second, size_t second_size, void *context) {
    (void)context;
    assert((char *)second == (char *)first + first_size);
    assert(second_size == first_size);
    return NC_REJECTED;
}
static NCPreparation never_pair(void *first, size_t first_size,
                               void *second, size_t second_size, void *context) {
    (void)first; (void)first_size; (void)second; (void)second_size; (void)context;
    assert(!"a pair with its second region above the ceiling was prepared");
    return NC_REJECTED;
}
int main(void) {
    size_t page = (size_t)getpagesize();
    assert(early_low && (char *)early_low_end - (char *)early_low >= (ptrdiff_t)(4 * page));
    void *base = early_low;
    preserve_low_tail = true;
    void *first = map_low(page, PROT_READ);
    assert(first == base && early_low == (char *)base + page);
    vm_address_t collision = (vm_address_t)early_low;
    assert(vm_allocate(mach_task_self(), &collision, page, VM_FLAGS_FIXED) != KERN_SUCCESS);
    void *second = map_low(page, PROT_READ);
    assert(second == (char *)first + page);
    preserve_low_tail = false;
    release_low_tail();
    assert(!early_low && !early_low_end);
    munmap(first, page); munmap(second, page);

    // Rejecting the transaction releases the unused reservation as well as
    // both staged regions; no published or quarantined ownership remains.
    reserve_low_arena();
    NativeCodeMemory a={0}, b={0}, qa={0}, qb={0};
    assert(!nc_create_pair(&a,page,UINTPTR_MAX,&b,page,reject_pair,NULL,&qa,&qb));
    assert(!early_low && !early_low_end && !preserve_low_tail);
    assert(!a.executable && !b.executable && !qa.executable && !qb.executable);

    // The second region has the first one's ceiling. With room for the first
    // only, the pair is refused for lack of room and nothing is prepared.
    reserve_low_arena();
    assert(early_low);
    uintptr_t ceiling=(uintptr_t)early_low+page;
    assert(!nc_create_pair(&a,page,ceiling,&b,page,never_pair,NULL,&qa,&qb) && errno==ENOSPC);
    assert(!early_low && !early_low_end && !preserve_low_tail);
    assert(!a.executable && !b.executable && !qa.executable && !qb.executable);
    // A second gap is held beside the first: what the first cannot hold
    // comes from the second, and nc_low_room reports both.
    reserve_low_arena();
    size_t room[2]; nc_low_room(room);
    assert(room[0] && room[0] == (size_t)((char *)early_low_end - (char *)early_low));
    if (room[1]) {
        assert(room[1] <= room[0]);
        void *other = early_second;
        // Leave one page in the first gap, then ask for two.
        early_low = (char *)early_low_end - page;
        munmap(base = (char *)early_low_end - room[0], room[0] - page);
        preserve_low_tail = true;
        void *two = map_low(2 * page, PROT_READ);
        assert(two == other && early_low && early_second == (char *)other + 2 * page);
        void *last = early_low;
        void *one = map_low(page, PROT_READ);
        assert(one == last && !early_low);
        preserve_low_tail = false;
        release_low_tail();
        assert(!early_second && !early_second_end);
        munmap(two, 2 * page); munmap(one, page);
    } else release_low_tail();
    nc_low_room(room);
    assert(!room[0] && !room[1]);
    puts("PASS: paired low reservation survives alias allocation, releases on rejection, and keeps the second region under the ceiling");
}
