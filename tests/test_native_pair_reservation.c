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
    puts("PASS: paired low reservation survives alias allocation and releases on rejection");
}
