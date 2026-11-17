#include "NativeCodeMemory.h"
#include <TargetConditionals.h>
#include <errno.h>
#include <stdio.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif

size_t nc_available_memory(void) {
#if TARGET_OS_IPHONE
    return (size_t)os_proc_available_memory();
#else
    return 0;
#endif
}
size_t nc_launch_limit(void) {
    size_t limit = NC_MAX_ARENA, available = nc_available_memory();
    if (available && available < limit) limit = available;
    size_t page = (size_t)getpagesize();
    return limit - limit % page;
}
size_t nc_arena_limit(void) {
    // Preserve the existing External JIT default; larger arenas are explicit profiles.
    size_t limit = (size_t)1024 * 1024 * 1024, available = nc_available_memory();
    // Twice for the alias, and the application allocates beside it.
    if (available && available / 4 < limit) limit = available / 4;
    size_t page = (size_t)getpagesize();
    return limit - limit % page;
}

void nc_destroy(NativeCodeMemory *memory) {
    if (memory->quarantined) return;
    if (memory->writable) vm_deallocate(mach_task_self(), (vm_address_t)memory->writable, memory->size);
    if (memory->executable) munmap(memory->executable, memory->size);
    *memory = (NativeCodeMemory){0};
}
// The arena's executable half below 64 GB. Left to the kernel it can land in the
// 448-512 GB range that an iPad app's large reservations need (one Windows process each
// in single-app mode); there it crowded those processes' own views. By the time an arena
// is made the low gigabytes are often too fragmented for one, so a placeholder of the
// largest arena is reserved there when the runtime loads, and the arena takes its place.
// The system's own heap starts at a random place in those gigabytes before any
// of our code runs and often leaves no single gap for a large arena pair, so the
// second largest gap is held as well: a pair may take one region from each
// (nc_low_room tells the caller what there is).
static void *early_low, *early_low_end, *early_second, *early_second_end;
static _Thread_local bool preserve_low_tail;
static void release_low_tail(void) {
    if (early_low) munmap(early_low, (size_t)((char *)early_low_end - (char *)early_low));
    if (early_second) munmap(early_second, (size_t)((char *)early_second_end - (char *)early_second));
    early_low = early_low_end = early_second = early_second_end = NULL;
}
void nc_low_room(size_t room[2]) {
    room[0] = early_low ? (size_t)((char *)early_low_end - (char *)early_low) : 0;
    room[1] = early_second ? (size_t)((char *)early_second_end - (char *)early_second) : 0;
}
static void *map_low_hint(size_t size, int prot) {
    const uintptr_t low_end = (uintptr_t)1 << 36;
    // A free interval may straddle a GiB boundary: testing only GiB-aligned
    // starts misses it. Let mmap choose a nearby free interval first, but
    // reject an ignored hint rather than accepting a high arena.
    void *near = mmap((void *)((uintptr_t)1 << 32), size, prot, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (near != MAP_FAILED) {
        if ((uintptr_t)near >= ((uintptr_t)1 << 32) && (uintptr_t)near <= low_end - size)
            return near;
        munmap(near, size);
    }
    for (uintptr_t hint = (uintptr_t)1 << 32; hint + size <= low_end; hint += (uintptr_t)1 << 24) {
        // mmap may ignore its hint even when the requested range is free.
        // Claim that exact range without overwrite, then replace only our own
        // reservation. Never use MAP_FIXED against an unclaimed address.
        vm_address_t reserved = hint;
        if (vm_allocate(mach_task_self(), &reserved, size, VM_FLAGS_FIXED) != KERN_SUCCESS)
            continue;
        void *mapped = mmap((void *)reserved, size, prot, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
        if (mapped != MAP_FAILED) return mapped;
        vm_deallocate(mach_task_self(), reserved, size);
    }
    return MAP_FAILED;
}
// What is free between 4 and 64 GiB, for the log of a launch that found no
// room: the largest gaps, from this process's own map.
static void log_low_gaps(void) {
    const vm_address_t low=(vm_address_t)1<<32, high=(vm_address_t)1<<36;
    struct { vm_address_t start; vm_size_t size; } largest[4]={{0,0}};
    vm_address_t cursor=low;
    while (cursor<high) {
        vm_address_t address=cursor; vm_size_t size=0;
        vm_region_basic_info_data_64_t info; mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64; mach_port_t object=MACH_PORT_NULL;
        kern_return_t result=vm_region_64(mach_task_self(),&address,&size,VM_REGION_BASIC_INFO_64,(vm_region_info_t)&info,&count,&object);
        vm_address_t next=result==KERN_SUCCESS && address<high ? address : high;
        if (next>cursor) {
            vm_size_t gap=next-cursor; vm_address_t start=cursor;
            for (size_t i=0;i<4;i++) if (gap>largest[i].size) {
                vm_size_t s=largest[i].size; vm_address_t a=largest[i].start;
                largest[i].size=gap; largest[i].start=start; gap=s; start=a;
            }
        }
        if (result!=KERN_SUCCESS || address>=high) break;
        // What holds the 2 GiB under the shared region: each mapping of 4 MiB or more.
        if (address<((vm_address_t)6<<30) && size>=((vm_size_t)4<<20)) {
            vm_address_t at=address; vm_size_t length=0;
            vm_region_extended_info_data_t more; mach_msg_type_number_t words=VM_REGION_EXTENDED_INFO_COUNT; mach_port_t unused=MACH_PORT_NULL;
            unsigned tag=vm_region_64(mach_task_self(),&at,&length,VM_REGION_EXTENDED_INFO,(vm_region_info_t)&more,&words,&unused)==KERN_SUCCESS ? more.user_tag : 0;
            fprintf(stderr,"[native-memory] used below 6 GiB: %#llx, %llu MiB, protection %d/%d, tag %u\n",(unsigned long long)address,
                (unsigned long long)(size>>20),info.protection,info.max_protection,tag);
        }
        cursor=address+size;
    }
    for (size_t i=0;i<4 && largest[i].size;i++)
        fprintf(stderr,"[native-memory] free below 64 GiB: %#llx, %llu MiB\n",(unsigned long long)largest[i].start,(unsigned long long)(largest[i].size>>20));
}
__attribute__((constructor)) static void reserve_low_arena(void) {
    // Keep the largest low gap available at startup, even when the ceiling
    // itself does not fit between the host's initial mappings. A coarse
    // 256 MiB decrement can discard enough space to miss a 1338 MiB arena.
    for (size_t size=NC_MAX_ARENA; size>=((size_t)256<<20); size-=((size_t)16<<20)) {
        void *placeholder=map_low_hint(size,PROT_NONE);
        if (placeholder!=MAP_FAILED) { early_low=placeholder; early_low_end=(char *)placeholder+size; break; }
    }
    // The next largest gap, searched while the first is held.
    for (size_t size=early_low ? (size_t)((char *)early_low_end-(char *)early_low) : 0; size>=((size_t)64<<20); size-=((size_t)16<<20)) {
        void *placeholder=map_low_hint(size,PROT_NONE);
        if (placeholder!=MAP_FAILED) { early_second=placeholder; early_second_end=(char *)placeholder+size; break; }
    }
}
static void *map_low(size_t size, int prot) {
    fprintf(stderr,"[native-memory] early low base=%p bytes=%zu second=%p bytes=%zu requested=%zu\n",early_low,early_low ? (size_t)((char *)early_low_end-(char *)early_low) : 0,
            early_second,early_second ? (size_t)((char *)early_second_end-(char *)early_second) : 0,size);
    if (early_low && size <= (size_t)((char *)early_low_end - (char *)early_low)) {
        void *mapped = mmap(early_low, size, prot, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
        if (mapped == early_low) {
            // A paired allocation must keep its second region reserved while
            // vm_remap creates the first region's writable alias.
            early_low = (char *)early_low + size;
            if (early_low == early_low_end) early_low = early_low_end = NULL;
            if (!preserve_low_tail) release_low_tail();
            return mapped;
        }
    }
    // What the first gap cannot hold may fit the second.
    if (early_second && size <= (size_t)((char *)early_second_end - (char *)early_second)) {
        void *mapped = mmap(early_second, size, prot, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
        if (mapped == early_second) {
            early_second = (char *)early_second + size;
            if (early_second == early_second_end) early_second = early_second_end = NULL;
            if (!preserve_low_tail) release_low_tail();
            return mapped;
        }
    }
    // Undersized placeholders must not obstruct a larger contiguous claim.
    release_low_tail();
    void *mapped = map_low_hint(size, prot);
    if (mapped==MAP_FAILED) {
        fprintf(stderr,"[native-memory] low arena unavailable size=%zu errno=%d\n",size,errno);
        log_low_gaps();
    }
    return mapped != MAP_FAILED ? mapped : mmap(NULL, size, prot, MAP_PRIVATE | MAP_ANON, -1, 0);
}

bool nc_create_managed(NativeCodeMemory *memory, size_t size, NCPrepare prepare,
                       void *context, NativeCodeMemory *quarantine) {
    return nc_create_managed_below(memory, size, UINTPTR_MAX, prepare, context, quarantine);
}

bool nc_create_managed_below(NativeCodeMemory *memory, size_t size, uintptr_t ceiling,
                             NCPrepare prepare, void *context, NativeCodeMemory *quarantine) {
    size_t page = (size_t)getpagesize();
    if (!memory || !quarantine || memory == quarantine ||
        memory->size || memory->executable || memory->writable ||
        quarantine->size || quarantine->executable || quarantine->writable || !size ||
        size % page || size > NC_MAX_ARENA || !prepare) {
        errno = EINVAL; return false;
    }
    NativeCodeMemory staged = {.size = size};
    staged.executable = map_low(size, PROT_READ | PROT_EXEC);
    if (staged.executable == MAP_FAILED) return false;
    uintptr_t start = (uintptr_t)staged.executable;
    if (start >= ceiling || size > ceiling - start) {
        nc_destroy(&staged);
        errno = ENOSPC;
        return false;
    }
    vm_address_t alias = 0;
    vm_prot_t current = 0, maximum = 0;
    kern_return_t result = vm_remap(mach_task_self(), &alias, size, 0, VM_FLAGS_ANYWHERE,
                                   mach_task_self(), (vm_address_t)staged.executable, false,
                                   &current, &maximum, VM_INHERIT_NONE);
    if (result != KERN_SUCCESS) {
        nc_destroy(&staged); errno = result == KERN_NO_SPACE ? ENOMEM : EACCES; return false;
    }
    staged.writable = (void *)alias;
    NCPreparation outcome = prepare(staged.executable, size, context);
    if (outcome != NC_PREPARED && outcome != NC_REJECTED) {
        staged.quarantined = true; *quarantine = staged;
        errno = EINPROGRESS; return false;
    }
    if (outcome == NC_REJECTED) {
        nc_destroy(&staged); errno = EPERM; return false;
    }
    if (mprotect(staged.writable, size, PROT_READ | PROT_WRITE)) {
        int saved = errno; nc_destroy(&staged); errno = saved; return false;
    }
    staged.published = true; *memory = staged;
    return true;
}
bool nc_adopt(NativeCodeMemory *memory, void *executable, size_t size) {
    size_t page = (size_t)getpagesize();
    // The caller sized the request; the ceiling still applies.
    if (!memory || memory->size || memory->executable || memory->writable || !executable ||
        !size || size % page || size > NC_MAX_ARENA || (uintptr_t)executable % page) {
        errno = EINVAL; return false;
    }
    vm_address_t alias = 0;
    vm_prot_t current = 0, maximum = 0;
    kern_return_t result = vm_remap(mach_task_self(), &alias, size, 0, VM_FLAGS_ANYWHERE,
                                    mach_task_self(), (vm_address_t)executable, false,
                                    &current, &maximum, VM_INHERIT_NONE);
    if (result != KERN_SUCCESS) { errno = result == KERN_NO_SPACE ? ENOMEM : EACCES; return false; }
    if (mprotect((void *)alias, size, PROT_READ | PROT_WRITE)) {
        int saved = errno; vm_deallocate(mach_task_self(), alias, size); errno = saved; return false;
    }
    *memory = (NativeCodeMemory){.executable = executable, .writable = (void *)alias,
                                 .size = size, .published = true};
    return true;
}
typedef struct { NCPublish function; void *context; } LegacyPublisher;
static NCPreparation legacy_prepare(void *address, size_t size, void *opaque) {
    LegacyPublisher *publisher = opaque;
    return publisher->function(address,size,publisher->context) ? NC_PREPARED : NC_REJECTED;
}
bool nc_create(NativeCodeMemory *memory, size_t size, NCPublish publish, void *context) {
    if (!publish) { errno = EINVAL; return false; }
    LegacyPublisher publisher = {publish,context}; NativeCodeMemory unused = {0};
    return nc_create_managed(memory,size,legacy_prepare,&publisher,&unused);
}
bool nc_write(NativeCodeMemory *memory, size_t offset, const void *bytes, size_t size) {
    if (!memory->published || memory->quarantined || !memory->executable || !memory->writable || !bytes || offset > memory->size ||
        size > memory->size - offset) { errno = EINVAL; return false; }
    if (!size) return true;
    char *destination = (char *)memory->writable + offset;
    memcpy(destination, bytes, size);
    sys_dcache_flush(destination, size);
    sys_icache_invalidate((char *)memory->executable + offset, size);
    return true;
}

typedef struct {
    NativeCodeMemory *second, *quarantine;
    size_t second_size;
    NCPreparePair prepare;
    void *context, *first_address;
    size_t first_size;
    uintptr_t ceiling;
    int second_errno;
    NCPreparation outcome;
} PairPreparation;
static NCPreparation prepare_pair_second(void *address,size_t size,void *opaque) {
    PairPreparation *pair=opaque;
    pair->outcome=pair->prepare(pair->first_address,pair->first_size,address,size,pair->context);
    return pair->outcome;
}
static NCPreparation prepare_pair_first(void *address,size_t size,void *opaque) {
    PairPreparation *pair=opaque;
    pair->first_address=address; pair->first_size=size;
    // The second region has the first one's ceiling: a code pool that the
    // kernel put high instead is refused here, before anything is prepared.
    if(nc_create_managed_below(pair->second,pair->second_size,pair->ceiling,prepare_pair_second,pair,pair->quarantine))
        return NC_PREPARED;
    pair->second_errno=errno;
    return pair->quarantine->quarantined ? NC_UNCERTAIN : NC_REJECTED;
}
bool nc_create_pair(NativeCodeMemory *first,size_t first_size,uintptr_t first_ceiling,
                    NativeCodeMemory *second,size_t second_size,NCPreparePair prepare,
                    void *context,NativeCodeMemory *first_quarantine,NativeCodeMemory *second_quarantine) {
    NativeCodeMemory *owners[]={first,second,first_quarantine,second_quarantine};
    for(size_t i=0;i<4;i++) {
        if(!owners[i] || owners[i]->executable || owners[i]->writable || owners[i]->size ||
           owners[i]->published || owners[i]->quarantined) { errno=EINVAL;return false; }
        for(size_t j=0;j<i;j++) if(owners[i]==owners[j]) { errno=EINVAL;return false; }
    }
    size_t page=(size_t)getpagesize();
    if(!prepare || !first_size || !second_size || first_size%page || second_size%page ||
       second_size>NC_MAX_ARENA || first_size>NC_MAX_ARENA-second_size) { errno=EINVAL;return false; }
    PairPreparation pair={.second=second,.quarantine=second_quarantine,.second_size=second_size,
                          .prepare=prepare,.context=context,.ceiling=first_ceiling,.outcome=NC_REJECTED};
    bool previous_preserve = preserve_low_tail;
    preserve_low_tail = true;
    bool ok=nc_create_managed_below(first,first_size,first_ceiling,prepare_pair_first,&pair,first_quarantine);
    preserve_low_tail = previous_preserve;
    if (!preserve_low_tail) release_low_tail();
    if(!ok && !first_quarantine->quarantined && !second_quarantine->quarantined) nc_destroy(second);
    // No room for the second region is the answer the caller acts on.
    if(!ok && pair.second_errno==ENOSPC) errno=ENOSPC;
    return ok;
}
