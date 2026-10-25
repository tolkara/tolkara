/* Test host only: real native backing outside Wine's constrained range.
 * Exercises Wine bookkeeping, not software-fault performance. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>

static uintptr_t begin=0x80000000000ULL, end=0x82000000000ULL, next;
__attribute__((constructor)) static void initialize(void) {
    mach_vm_address_t address=begin;
    assert(mach_vm_allocate(mach_task_self(),&address,end-begin,VM_FLAGS_FIXED)==KERN_SUCCESS);
    assert(!mprotect((void *)begin,end-begin,PROT_NONE)); next=begin;
}
uintptr_t tolkara_software_address_end(void) { return end; }
bool tolkara_software_address(const void *p) { return (uintptr_t)p>=begin && (uintptr_t)p<end; }
void *tolkara_software_reserve_aligned(size_t size,size_t alignment,size_t offset,int prot) {
    uintptr_t at=next+((offset-(next&(alignment-1)))&(alignment-1));
    if(at>end || size>end-at || mprotect((void *)at,size,prot))return MAP_FAILED;
    next=at+size;return (void *)at;
}
