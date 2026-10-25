#include "GuestSparseMemory.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

enum { REGION_LIMIT = 256 };
typedef struct { uint64_t start, end; unsigned prot, maxprot; } Region;
typedef struct { uint64_t address, generation; size_t backing; } Page;
_Static_assert(ATOMIC_BOOL_LOCK_FREE==2,"Sparse memory requires a signal-safe atomic lock");
typedef struct {
    atomic_bool lock;
    uint64_t base, end, generation, mapping_generation;
    unsigned char *backing;
    unsigned char **blocks;
    size_t capacity, resident, next_backing, free_count, slot_count;
    size_t *free_backing;
    Page *pages;
    Region regions[REGION_LIMIT];
    size_t count;
} Space;

static void lock(Space *s) {
    for (;;) {
        if(!atomic_exchange_explicit(&s->lock,true,memory_order_acquire)) return;
        // Read while another thread owns the lock instead of repeatedly
        // writing its cache line. This path also runs in the fault handler.
        while(atomic_load_explicit(&s->lock,memory_order_relaxed)) {
#if defined(__aarch64__)
            __asm__ volatile("yield");
#endif
        }
    }
}
static void unlock(Space *s) {
    atomic_store_explicit(&s->lock,false,memory_order_release);
}
static bool aligned(uint64_t a, uint64_t n) {
    return n && !(a % GM_PAGE_SIZE) && !(n % GM_PAGE_SIZE) && n <= UINT64_MAX - a;
}
static bool contains(const Space *s, uint64_t a, uint64_t n) {
    return a >= s->base && a <= s->end && n <= s->end - a;
}
static bool mapping_range(const Space *s, uint64_t a, uint64_t n) {
    return aligned(a, n) && contains(s, a, n);
}
static size_t page_slot(const Space *s, uint64_t address, bool insertion) {
    uint64_t h = address / GM_PAGE_SIZE;
    h ^= h >> 30; h *= UINT64_C(0xbf58476d1ce4e5b9);
    h ^= h >> 27; h *= UINT64_C(0x94d049bb133111eb);
    h ^= h >> 31;
    size_t first_deleted = SIZE_MAX;
    for (size_t step = 0, i = (size_t)h & (s->slot_count - 1);
         step < s->slot_count; ++step, i = (i + 1) & (s->slot_count - 1)) {
        uint64_t found = s->pages[i].address;
        if (found == address) return i;
        if (!found) return insertion ? (first_deleted != SIZE_MAX ? first_deleted : i) : SIZE_MAX;
        if (found == UINT64_MAX && first_deleted == SIZE_MAX) first_deleted = i;
    }
    return insertion ? first_deleted : SIZE_MAX;
}
static void discard_pages(Space *s, uint64_t from, uint64_t to) {
    for (size_t i = 0; i < s->slot_count; ++i) {
        Page *p = &s->pages[i];
        if (p->address && p->address != UINT64_MAX && p->address >= from && p->address < to) {
            s->free_backing[s->free_count++] = p->backing;
            p->address = UINT64_MAX;
            --s->resident;
        }
    }
}
static bool append(Region *regions, size_t *count, Region r) {
    if (r.start == r.end) return true;
    if (*count && regions[*count - 1].end == r.start &&
        regions[*count - 1].prot == r.prot && regions[*count - 1].maxprot == r.maxprot) {
        regions[*count - 1].end = r.end;
        return true;
    }
    if (*count == REGION_LIMIT) return false;
    regions[(*count)++] = r;
    return true;
}

static unsigned char *backing_page(Space *s, size_t index) {
    return s->blocks ? s->blocks[index] : s->backing + index * GM_PAGE_SIZE;
}
static void release_backing(Space *s) {
    if(s->blocks) {
        for(size_t i=0;i<s->capacity;i++)free(s->blocks[i]);
        free(s->blocks);
    } else if(s->backing && s->backing!=MAP_FAILED) munmap(s->backing,s->capacity*GM_PAGE_SIZE);
}
static GMResult initialize(GMSparseMemory *memory, uint64_t base, uint64_t size,
                           size_t backing_bytes, bool small_blocks) {
    if (!memory || memory->implementation || !base || !aligned(base, size) ||
        !backing_bytes || backing_bytes % GM_PAGE_SIZE) return GM_INVALID;
    size_t capacity = backing_bytes / GM_PAGE_SIZE, slots = 16;
    if (capacity > SIZE_MAX / 2) return GM_NOMEM;
    while (slots < capacity * 2) {
        if (slots > SIZE_MAX / 2) return GM_NOMEM;
        slots *= 2;
    }
    if (slots > SIZE_MAX / sizeof(Page) || capacity > SIZE_MAX / sizeof(size_t) ||
        capacity > SIZE_MAX / sizeof(unsigned char *)) return GM_NOMEM;
    Space *s = calloc(1, sizeof *s);
    if (!s) return GM_NOMEM;
    atomic_init(&s->lock,false);
    s->base = base; s->end = base + size;
    s->capacity = capacity; s->slot_count = slots;
    bool backing_ok=true;
    if(small_blocks) {
        s->blocks=calloc(capacity,sizeof *s->blocks);
        backing_ok=s->blocks!=NULL;
        for(size_t i=0;backing_ok && i<capacity;i++) {
            s->blocks[i]=malloc(GM_PAGE_SIZE);
            backing_ok=s->blocks[i]!=NULL;
        }
    } else {
        s->backing=mmap(NULL,backing_bytes,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
        backing_ok=s->backing!=MAP_FAILED;
    }
    s->pages = calloc(slots, sizeof *s->pages);
    s->free_backing = calloc(capacity, sizeof *s->free_backing);
    if (!backing_ok || !s->pages || !s->free_backing) {
        release_backing(s);
        free(s->pages); free(s->free_backing); free(s);
        return GM_NOMEM;
    }
    memory->implementation = s;
    return GM_OK;
}
GMResult gm_sparse_init(GMSparseMemory *memory, uint64_t base, uint64_t size, size_t backing_bytes) {
    return initialize(memory,base,size,backing_bytes,false);
}
GMResult gm_sparse_init_blocks(GMSparseMemory *memory, uint64_t base, uint64_t size, size_t backing_bytes) {
    return initialize(memory,base,size,backing_bytes,true);
}
void gm_sparse_destroy(GMSparseMemory *memory) {
    if (!memory || !memory->implementation) return;
    Space *s = memory->implementation;
    release_backing(s);
    free(s->pages); free(s->free_backing); free(s);
    memory->implementation = NULL;
}
GMResult gm_sparse_find_aligned(GMSparseMemory *memory, uint64_t size, uint64_t alignment,
                                uint64_t offset, uint64_t *address) {
    Space *s = memory ? memory->implementation : NULL;
    if (!s || !address || !aligned(0, size) || alignment < GM_PAGE_SIZE ||
        (alignment & (alignment - 1)) || offset >= alignment || (offset & (GM_PAGE_SIZE - 1)))
        return GM_INVALID;
    lock(s);
    uint64_t candidate = s->base, mask = alignment - 1;
    GMResult result = GM_NOMEM;
    for (size_t i = 0; i <= s->count; ++i) {
        uint64_t delta = (offset - (candidate & mask)) & mask;
        if (candidate > UINT64_MAX - delta) break;
        candidate += delta;
        if (candidate > s->end || size > s->end - candidate) break;
        if (i == s->count || (candidate <= s->regions[i].start &&
                             size <= s->regions[i].start - candidate)) {
            *address = candidate;
            result = GM_OK;
            break;
        }
        if (candidate < s->regions[i].end) candidate = s->regions[i].end;
    }
    unlock(s);
    return result;
}
GMResult gm_sparse_find_free(GMSparseMemory *memory, uint64_t size, uint64_t *address) {
    return gm_sparse_find_aligned(memory, size, GM_PAGE_SIZE, 0, address);
}

enum Operation { MAP, UNMAP, PROTECT };
static GMResult change(GMSparseMemory *memory, uint64_t a, uint64_t n,
                        unsigned prot, unsigned maxprot, bool replace, enum Operation op) {
    Space *s = memory ? memory->implementation : NULL;
    if (!s || !mapping_range(s, a, n) || (maxprot & ~7u) || (prot & ~maxprot)) return GM_INVALID;
    lock(s);
    uint64_t end = a + n, covered = a;
    GMResult result = GM_OK;
    for (size_t i = 0; i < s->count; ++i) {
        Region r = s->regions[i];
        if (r.end <= a || r.start >= end) continue;
        if (op == MAP && !replace) { result = GM_OVERLAP; goto done; }
        if (op == PROTECT) {
            if (r.start > covered) { result = GM_UNMAPPED; goto done; }
            covered = r.end < end ? r.end : end;
        }
    }
    if (op == PROTECT && covered != end) { result = GM_UNMAPPED; goto done; }
    if (op == PROTECT) for (size_t i = 0; i < s->count; ++i) {
        Region r = s->regions[i];
        if (r.end > a && r.start < end && (prot & ~r.maxprot)) {
            result = GM_PROTECTION; goto done;
        }
    }
    Region next[REGION_LIMIT];
    size_t count = 0;
    bool inserted = op != MAP;
    for (size_t i = 0; i < s->count; ++i) {
        Region r = s->regions[i];
        if (r.end <= a) {
            if (!append(next, &count, r)) goto full;
            continue;
        }
        if (!inserted) {
            if (r.start < a && !append(next, &count, (Region){r.start, a, r.prot, r.maxprot})) goto full;
            if (!append(next, &count, (Region){a, end, prot, maxprot})) goto full;
            inserted = true;
        }
        if (r.start >= end) {
            if (!append(next, &count, r)) goto full;
            continue;
        }
        if (op != MAP && r.start < a && !append(next, &count, (Region){r.start, a, r.prot, r.maxprot})) goto full;
        if (op == PROTECT && !append(next, &count, (Region){r.start > a ? r.start : a,
                r.end < end ? r.end : end, prot, r.maxprot})) goto full;
        if (r.end > end && !append(next, &count, (Region){end, r.end, r.prot, r.maxprot})) goto full;
    }
    if (!inserted && !append(next, &count, (Region){a, end, prot, maxprot})) goto full;
    if (s->resident && op != PROTECT) discard_pages(s, a, end);
    memcpy(s->regions, next, count * sizeof *next);
    s->count = count;
    ++s->mapping_generation;
    goto done;
full:
    result = GM_NOMEM;
done:
    unlock(s);
    return result;
}
GMResult gm_sparse_map(GMSparseMemory *m, uint64_t a, uint64_t n, unsigned p, unsigned max, bool replace) {
    return change(m, a, n, p, max, replace, MAP);
}
GMResult gm_sparse_unmap(GMSparseMemory *m, uint64_t a, uint64_t n) {
    return change(m, a, n, 0, 0, false, UNMAP);
}
GMResult gm_sparse_protect(GMSparseMemory *m, uint64_t a, uint64_t n, unsigned p) {
    return change(m, a, n, p, 7, false, PROTECT);
}

static GMResult check_access(const Space *s, uint64_t a, size_t n, unsigned permission) {
    if (!contains(s, a, n)) return GM_INVALID;
    if (!n) return GM_OK;
    uint64_t end = a + n, covered = a;
    for (size_t i = 0; i < s->count && covered < end; ++i) {
        Region r = s->regions[i];
        if (r.end <= covered) continue;
        if (r.start > covered) break;
        if ((r.prot & permission) != permission) return GM_PROTECTION;
        covered = r.end < end ? r.end : end;
    }
    return covered == end ? GM_OK : GM_UNMAPPED;
}
static GMResult access_locked(Space *s, uint64_t a, void *buffer, size_t n, bool write) {
    if (n && !buffer) return GM_INVALID;
    GMResult result = check_access(s, a, n, write ? GM_WRITE : GM_READ);
    if (result != GM_OK || !n) return result;
    uint64_t end = a + n;
    if (write) {
        size_t needed = 0;
        for (uint64_t page = a - a % GM_PAGE_SIZE; page < end; page += GM_PAGE_SIZE)
            if (page_slot(s, page, false) == SIZE_MAX && ++needed > s->capacity - s->resident) {
                result = GM_NOMEM; goto done;
            }
        ++s->generation;
    }
    unsigned char *bytes = buffer;
    while (n) {
        size_t offset = (size_t)(a % GM_PAGE_SIZE), chunk = GM_PAGE_SIZE - offset;
        uint64_t page = a - offset;
        if (chunk > n) chunk = n;
        size_t slot = page_slot(s, page, false);
        if (write && slot == SIZE_MAX) {
            slot = page_slot(s, page, true);
            // The table is at most half full; preflight guaranteed capacity.
            size_t backing = s->free_count ? s->free_backing[--s->free_count] : s->next_backing++;
            memset(backing_page(s,backing), 0, GM_PAGE_SIZE);
            s->pages[slot] = (Page){.address=page,.backing=backing};
            ++s->resident;
        }
        if (write) {
            memcpy(backing_page(s,s->pages[slot].backing) + offset, bytes, chunk);
            s->pages[slot].generation=s->generation;
        }
        else if (slot != SIZE_MAX) memcpy(bytes, backing_page(s,s->pages[slot].backing) + offset, chunk);
        else memset(bytes, 0, chunk);
        a += chunk; bytes += chunk; n -= chunk;
    }
done:
    return result;
}
GMResult gm_sparse_prepare(GMSparseMemory *memory, uint64_t a, size_t n, unsigned permissions) {
    Space *s = memory ? memory->implementation : NULL;
    if (!s || (permissions & ~(GM_READ | GM_WRITE))) return GM_INVALID;
    lock(s);
    GMResult result = check_access(s, a, n, permissions);
    if (result != GM_OK || !n || !(permissions & GM_WRITE)) goto done;
    uint64_t end = a + n;
    size_t needed = 0;
    for (uint64_t page = a - a % GM_PAGE_SIZE; page < end; page += GM_PAGE_SIZE)
        if (page_slot(s, page, false) == SIZE_MAX && ++needed > s->capacity - s->resident) {
            result = GM_NOMEM; goto done;
        }
    for (uint64_t page = a - a % GM_PAGE_SIZE; page < end; page += GM_PAGE_SIZE) {
        if (page_slot(s, page, false) != SIZE_MAX) continue;
        size_t slot = page_slot(s, page, true);
        size_t backing = s->free_count ? s->free_backing[--s->free_count] : s->next_backing++;
        memset(backing_page(s,backing), 0, GM_PAGE_SIZE);
        s->pages[slot] = (Page){.address=page,.backing=backing};
        ++s->resident;
    }
done:
    unlock(s);
    return result;
}
static GMResult access_memory(GMSparseMemory *memory, uint64_t a, void *buffer, size_t n, bool write) {
    Space *s = memory ? memory->implementation : NULL;
    if (!s) return GM_INVALID;
    lock(s);
    GMResult result = access_locked(s, a, buffer, n, write);
    unlock(s);
    return result;
}
GMResult gm_sparse_read(GMSparseMemory *m, uint64_t a, void *b, size_t n) {
    return access_memory(m, a, b, n, false);
}
GMResult gm_sparse_write(GMSparseMemory *m, uint64_t a, const void *b, size_t n) {
    return access_memory(m, a, (void *)b, n, true);
}
static bool atomic_size(uint64_t address, size_t size) {
    return size && size <= 16 && !(size & (size - 1)) && !(address % size);
}
static uint64_t page_generation(const Space *s,uint64_t address) {
    size_t slot=page_slot(s,address-address%GM_PAGE_SIZE,false);
    return slot==SIZE_MAX?0:s->pages[slot].generation;
}
GMResult gm_sparse_load_exclusive(GMSparseMemory *m, uint64_t a, void *b, size_t n,
                                  GMSparseExclusive *monitor) {
    Space *s = m ? m->implementation : NULL;
    if (!s || !monitor || !atomic_size(a, n)) return GM_INVALID;
    lock(s);
    GMResult result = access_locked(s, a, b, n, false);
    if (result == GM_OK) *monitor = (GMSparseExclusive){
        .address=a,.generation=page_generation(s,a),.mapping_generation=s->mapping_generation,.size=n,.valid=true};
    unlock(s);
    return result;
}
GMResult gm_sparse_store_exclusive(GMSparseMemory *m, uint64_t a, const void *b, size_t n,
                                   GMSparseExclusive *monitor, bool *stored) {
    Space *s = m ? m->implementation : NULL;
    if (!s || !monitor || !stored || !b || !atomic_size(a, n)) return GM_INVALID;
    lock(s);
    GMResult result = GM_OK;
    // A write to an unrelated page must not make all other threads retry.
    // Mapping changes still invalidate every monitor to cover recycling.
    bool valid = monitor->valid && monitor->address == a && monitor->size == n &&
        monitor->mapping_generation==s->mapping_generation && monitor->generation==page_generation(s,a);
    if (valid) result = access_locked(s, a, (void *)b, n, true);
    if (result == GM_OK) { *stored = valid; monitor->valid = false; }
    unlock(s);
    return result;
}
GMResult gm_sparse_compare_exchange(GMSparseMemory *m, uint64_t a, const void *expected,
                                    const void *desired, void *previous, size_t n) {
    Space *s = m ? m->implementation : NULL;
    if (!s || !expected || !desired || !previous || !atomic_size(a, n)) return GM_INVALID;
    lock(s);
    unsigned char old[16];
    // CAS requires both permissions even when the comparison fails.
    GMResult result = check_access(s, a, n, GM_READ | GM_WRITE);
    if (result == GM_OK) result = access_locked(s, a, old, n, false);
    if (result == GM_OK && !memcmp(old, expected, n)) result = access_locked(s, a, (void *)desired, n, true);
    if (result == GM_OK) memcpy(previous, old, n);
    unlock(s);
    return result;
}
GMResult gm_sparse_atomic(GMSparseMemory *m, uint64_t a, size_t n, GMSparseAtomic operation,
                          uint64_t operand, uint64_t *previous) {
    Space *s = m ? m->implementation : NULL;
    if (!s || !previous || n > 8 || !atomic_size(a, n) || (unsigned)operation > GM_ATOMIC_SWAP) return GM_INVALID;
    lock(s);
    unsigned char bytes[8];
    GMResult result = access_locked(s, a, bytes, n, false);
    if (result == GM_OK) {
        uint64_t old = 0, mask = n == 8 ? UINT64_MAX : (UINT64_C(1) << (n * 8)) - 1;
        for (size_t i = 0; i < n; ++i) old |= (uint64_t)bytes[i] << (i * 8);
        operand &= mask;
        uint64_t sign = UINT64_C(1) << (n * 8 - 1), value = 0;
        switch (operation) {
            case GM_ATOMIC_ADD: value = old + operand; break;
            case GM_ATOMIC_CLEAR: value = old & ~operand; break;
            case GM_ATOMIC_XOR: value = old ^ operand; break;
            case GM_ATOMIC_SET: value = old | operand; break;
            case GM_ATOMIC_SIGNED_MAX: value = (old ^ sign) > (operand ^ sign) ? old : operand; break;
            case GM_ATOMIC_SIGNED_MIN: value = (old ^ sign) < (operand ^ sign) ? old : operand; break;
            case GM_ATOMIC_UNSIGNED_MAX: value = old > operand ? old : operand; break;
            case GM_ATOMIC_UNSIGNED_MIN: value = old < operand ? old : operand; break;
            case GM_ATOMIC_SWAP: value = operand; break;
        }
        for (size_t i = 0; i < n; ++i) bytes[i] = (unsigned char)(value >> (i * 8));
        result = access_locked(s, a, bytes, n, true);
        if (result == GM_OK) *previous = old;
    }
    unlock(s);
    return result;
}
GMSparseStats gm_sparse_stats(GMSparseMemory *memory) {
    GMSparseStats result = {0};
    Space *s = memory ? memory->implementation : NULL;
    if (!s) return result;
    lock(s);
    for (size_t i = 0; i < s->count; ++i) result.reserved_bytes += s->regions[i].end - s->regions[i].start;
    result.write_operations = s->generation;
    result.regions = s->count; result.resident_pages = s->resident; result.capacity_pages = s->capacity;
    unlock(s);
    return result;
}
