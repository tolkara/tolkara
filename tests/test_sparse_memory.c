#include "GuestSparseMemory.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

static GMResult (*initialize)(GMSparseMemory *,uint64_t,uint64_t,size_t);

static const uint64_t base = UINT64_C(0x10000000000);
#define PAGE GM_PAGE_SIZE
#define GIB (UINT64_C(1) << 30)

static void write_statistics(void) {
    GMSparseMemory m={0};
    assert(initialize(&m,base,GIB,2*PAGE)==GM_OK);
    assert(gm_sparse_map(&m,base,PAGE,GM_READ|GM_WRITE,GM_READ|GM_WRITE,false)==GM_OK);
    uint64_t value=7,old=0,wrong=9;
    assert(gm_sparse_stats(&m).write_operations==0);
    assert(gm_sparse_read(&m,base,&old,8)==GM_OK);
    assert(gm_sparse_write(&m,base,NULL,0)==GM_OK);
    assert(gm_sparse_write(&m,base+PAGE,&value,8)==GM_UNMAPPED);
    assert(gm_sparse_stats(&m).write_operations==0);
    assert(gm_sparse_write(&m,base,&value,8)==GM_OK);
    assert(gm_sparse_compare_exchange(&m,base,&wrong,&old,&value,8)==GM_OK);
    assert(gm_sparse_stats(&m).write_operations==1); // failed comparison is only a read
    assert(gm_sparse_compare_exchange(&m,base,&value,&wrong,&old,8)==GM_OK);
    assert(gm_sparse_stats(&m).write_operations==2);
    assert(gm_sparse_unmap(&m,base,PAGE)==GM_OK);
    assert(gm_sparse_stats(&m).write_operations==2);
    gm_sparse_destroy(&m);
    assert(gm_sparse_stats(&m).write_operations==0);
}

static void aligned_reservations(void) {
    GMSparseMemory m = {0};
    assert(initialize(&m, base, 256 * GIB, 16 * PAGE) == GM_OK);
    const uint64_t pool = 16 * GIB, guard = 0x10000;
    uint64_t addresses[4];
    for (unsigned i = 0; i < 4; ++i) {
        uint64_t size = pool + (i & 1 ? guard : 0), offset = i & 1 ? pool - guard : 0;
        assert(gm_sparse_find_aligned(&m, size, pool, offset, &addresses[i]) == GM_OK);
        assert((addresses[i] & (pool - 1)) == offset);
        assert(gm_sparse_map(&m, addresses[i], size, 0, 3, false) == GM_OK);
        uint64_t at = addresses[i] + (i & 1 ? guard : 0), value = i + 23, result = 0;
        assert(gm_sparse_protect(&m, at, PAGE, 3) == GM_OK);
        assert(gm_sparse_write(&m, at, &value, sizeof value) == GM_OK);
        assert(gm_sparse_read(&m, at, &result, sizeof result) == GM_OK && result == value);
        if (i & 1) assert(gm_sparse_read(&m, addresses[i], &result, sizeof result) == GM_PROTECTION);
    }
    uint64_t untouched = 42;
    assert(gm_sparse_find_aligned(&m, PAGE, 3 * PAGE, 0, &untouched) == GM_INVALID);
    assert(gm_sparse_find_aligned(&m, PAGE, pool, 1, &untouched) == GM_INVALID);
    assert(gm_sparse_find_aligned(&m, PAGE, pool, pool, &untouched) == GM_INVALID);
    assert(gm_sparse_find_aligned(&m, 256 * GIB, pool, 0, &untouched) == GM_NOMEM);
    assert(untouched == 42);
    assert(gm_sparse_unmap(&m, addresses[1], pool + guard) == GM_OK);
    assert(gm_sparse_find_aligned(&m, pool + guard, pool, pool - guard, &untouched) == GM_OK);
    assert(untouched == addresses[1]);
    gm_sparse_destroy(&m);
}

static void large_reservations(void) {
    GMSparseMemory m = {0};
    assert(initialize(&m, base, 256 * GIB, 16 * PAGE) == GM_OK);
    const uint64_t sizes[] = {16 * GIB, 64 * GIB, 32 * GIB};
    uint64_t addresses[3], expected = base;
    for (unsigned i = 0; i < 3; ++i) {
        assert(gm_sparse_find_free(&m, sizes[i], &addresses[i]) == GM_OK);
        assert(addresses[i] == expected);
        assert(gm_sparse_map(&m, addresses[i], sizes[i], 3, 3, false) == GM_OK);
        expected += sizes[i];
    }
    GMSparseStats stats = gm_sparse_stats(&m);
    assert(stats.reserved_bytes == 112 * GIB && stats.resident_pages == 0);
    for (unsigned i = 0; i < 3; ++i) {
        uint64_t value = 99;
        assert(gm_sparse_read(&m, addresses[i], &value, sizeof value) == GM_OK && value == 0);
        assert(gm_sparse_read(&m, addresses[i] + sizes[i] - 8, &value, 8) == GM_OK && value == 0);
        value = i + 1;
        assert(gm_sparse_write(&m, addresses[i], &value, 8) == GM_OK);
        value += 10;
        assert(gm_sparse_write(&m, addresses[i] + sizes[i] - 8, &value, 8) == GM_OK);
    }
    assert(gm_sparse_stats(&m).resident_pages == 6);
    for (unsigned i = 0; i < 3; ++i) {
        uint64_t value = 0;
        assert(gm_sparse_read(&m, addresses[i], &value, 8) == GM_OK && value == i + 1);
        assert(gm_sparse_read(&m, addresses[i] + sizes[i] - 8, &value, 8) == GM_OK && value == i + 11);
    }
    assert(gm_sparse_map(&m, addresses[1], PAGE, 3, 3, false) == GM_OVERLAP);
    assert(gm_sparse_protect(&m, addresses[1], sizes[1], GM_EXEC) == GM_PROTECTION);
    assert(gm_sparse_unmap(&m, addresses[1], sizes[1]) == GM_OK);
    stats = gm_sparse_stats(&m);
    assert(stats.reserved_bytes == 48 * GIB && stats.resident_pages == 4);
    uint64_t found;
    assert(gm_sparse_find_free(&m, 64 * GIB, &found) == GM_OK && found == addresses[1]);
    assert(gm_sparse_map(&m, found, 64 * GIB, 3, 3, false) == GM_OK);
    uint64_t value = 99;
    assert(gm_sparse_read(&m, found, &value, 8) == GM_OK && value == 0);
    gm_sparse_destroy(&m);
}

static void exhaustion_and_recycling(void) {
    GMSparseMemory m = {0};
    assert(initialize(&m, base, GIB, 2 * PAGE) == GM_OK);
    assert(gm_sparse_map(&m, base, GIB, 3, 7, false) == GM_OK);
    uint64_t value = 7, out = 0;
    assert(gm_sparse_write(&m, base, &value, 8) == GM_OK);
    unsigned char input[2 * PAGE + 1], output[sizeof input];
    memset(input, 0x51, sizeof input);
    assert(gm_sparse_write(&m, base, input, sizeof input) == GM_NOMEM);
    assert(gm_sparse_read(&m, base, &out, 8) == GM_OK && out == 7);
    assert(gm_sparse_stats(&m).resident_pages == 1);
    assert(gm_sparse_protect(&m, base + PAGE, PAGE, GM_READ) == GM_OK);
    assert(gm_sparse_write(&m, base + PAGE - 1, input, 2) == GM_PROTECTION);
    assert(gm_sparse_unmap(&m, base + PAGE, PAGE) == GM_OK);
    memset(output, 0x92, sizeof output);
    assert(gm_sparse_read(&m, base, output, sizeof output) == GM_UNMAPPED);
    for (size_t i = 0; i < sizeof output; ++i) assert(output[i] == 0x92);
    assert(gm_sparse_map(&m, base, GIB, 3, 7, true) == GM_OK);
    assert(gm_sparse_stats(&m).resident_pages == 0);
    // Many more keys than hash slots exercise tombstone reuse and zero fill.
    for (unsigned i = 0; i < 4096; ++i) {
        uint64_t at = base + (uint64_t)i * PAGE;
        assert(gm_sparse_write(&m, at, &value, 8) == GM_OK);
        assert(gm_sparse_read(&m, at + 8, &out, 8) == GM_OK && out == 0);
        assert(gm_sparse_unmap(&m, at, PAGE) == GM_OK);
        assert(gm_sparse_map(&m, at, PAGE, 3, 7, false) == GM_OK);
    }
    assert(gm_sparse_stats(&m).resident_pages == 0);
    gm_sparse_destroy(&m);
}

static uint32_t random_value(uint32_t *state) {
    *state ^= *state << 13; *state ^= *state >> 17; *state ^= *state << 5;
    return *state;
}
static void reference_comparison(void) {
    GMSparseMemory sparse = {0}; GuestMemory dense = {0};
    assert(initialize(&sparse, base, 64 * PAGE, 64 * PAGE) == GM_OK);
    uint32_t rng = 0x31415926;
    for (unsigned step = 0; step < 20000; ++step) {
        uint64_t a = base + (random_value(&rng) % 60) * PAGE;
        uint64_t n = (1 + random_value(&rng) % 4) * PAGE;
        unsigned prot = random_value(&rng) & 7, maxprot = random_value(&rng) & 7;
        bool replace = random_value(&rng) & 1;
        GMResult expected, actual;
        switch (random_value(&rng) % 5) {
            case 0:
                prot &= maxprot;
                expected = gm_map(&dense, a, n, prot, maxprot, false, replace);
                actual = gm_sparse_map(&sparse, a, n, prot, maxprot, replace);
                break;
            case 1:
                expected = gm_unmap(&dense, a, n);
                actual = gm_sparse_unmap(&sparse, a, n);
                break;
            case 2:
                expected = gm_protect(&dense, a, n, prot);
                actual = gm_sparse_protect(&sparse, a, n, prot);
                break;
            case 3: {
                unsigned char bytes[17]; memset(bytes, (int)(step & 255), sizeof bytes);
                a += PAGE - 8;
                expected = gm_write(&dense, NULL, a, bytes, sizeof bytes);
                actual = gm_sparse_write(&sparse, a, bytes, sizeof bytes);
                break;
            }
            default: {
                unsigned char left[17], right[17];
                memset(left, 0x93, sizeof left); memset(right, 0x93, sizeof right);
                a += PAGE - 8;
                expected = gm_read(&dense, a, left, sizeof left);
                actual = gm_sparse_read(&sparse, a, right, sizeof right);
                assert(!memcmp(left, right, sizeof left));
                break;
            }
        }
        assert(expected == actual);
    }
    gm_destroy(&dense); gm_sparse_destroy(&sparse);
}
typedef struct { GMSparseMemory *memory; unsigned number; } Worker;
static void *worker(void *raw) {
    Worker *w = raw;
    uint64_t a = base + w->number * PAGE;
    for (uint64_t i = 0; i < 10000; ++i) {
        uint64_t out = UINT64_MAX;
        assert(gm_sparse_write(w->memory, a, &i, 8) == GM_OK);
        assert(gm_sparse_read(w->memory, a, &out, 8) == GM_OK && out == i);
    }
    return NULL;
}
static void concurrent_pages(void) {
    GMSparseMemory m = {0};
    assert(initialize(&m, base, GIB, 8 * PAGE) == GM_OK);
    assert(gm_sparse_map(&m, base, GIB, 3, 3, false) == GM_OK);
    pthread_t threads[8]; Worker workers[8];
    for (unsigned i = 0; i < 8; ++i) {
        workers[i] = (Worker){&m, i};
        assert(!pthread_create(&threads[i], NULL, worker, &workers[i]));
    }
    for (unsigned i = 0; i < 8; ++i) assert(!pthread_join(threads[i], NULL));
    assert(gm_sparse_stats(&m).resident_pages == 8);
    gm_sparse_destroy(&m);
}
static void atomic_operations(void) {
    GMSparseMemory m = {0};
    assert(initialize(&m, base, 2 * PAGE, PAGE) == GM_OK);
    assert(gm_sparse_map(&m, base, 2 * PAGE, 3, 3, false) == GM_OK);
    const struct { GMSparseAtomic operation; uint64_t initial, operand, expected; } cases[] = {
        {GM_ATOMIC_ADD, 250, 9, 3}, {GM_ATOMIC_CLEAR, 0xa5, 0x81, 0x24},
        {GM_ATOMIC_XOR, 0xa5, 0x81, 0x24}, {GM_ATOMIC_SET, 0xa5, 0x12, 0xb7},
        {GM_ATOMIC_SIGNED_MAX, 0xff, 1, 1}, {GM_ATOMIC_SIGNED_MIN, 0xff, 1, 0xff},
        {GM_ATOMIC_UNSIGNED_MAX, 0xff, 1, 0xff}, {GM_ATOMIC_UNSIGNED_MIN, 0xff, 1, 1},
        {GM_ATOMIC_SWAP, 23, 0x107, 7}
    };
    for (unsigned i = 0; i < sizeof cases / sizeof *cases; ++i) {
        unsigned char value = (unsigned char)cases[i].initial, out = 0;
        uint64_t old = 0;
        assert(gm_sparse_write(&m, base, &value, 1) == GM_OK);
        assert(gm_sparse_atomic(&m, base, 1, cases[i].operation, cases[i].operand, &old) == GM_OK);
        assert(old == value);
        assert(gm_sparse_read(&m, base, &out, 1) == GM_OK && out == cases[i].expected);
    }
    uint64_t initial[2] = {1, 2}, desired[2] = {3, 4}, previous[2] = {0};
    assert(gm_sparse_write(&m, base, initial, 16) == GM_OK);
    assert(gm_sparse_compare_exchange(&m, base, desired, initial, previous, 16) == GM_OK);
    assert(!memcmp(previous, initial, 16));
    assert(gm_sparse_compare_exchange(&m, base, initial, desired, previous, 16) == GM_OK);
    assert(!memcmp(previous, initial, 16));
    assert(gm_sparse_read(&m, base, previous, 16) == GM_OK && !memcmp(previous, desired, 16));
    GMSparseExclusive monitor = {0}; bool stored = true;
    assert(gm_sparse_load_exclusive(&m, base, previous, 16, &monitor) == GM_OK);
    assert(gm_sparse_store_exclusive(&m, base, initial, 16, &monitor, &stored) == GM_OK && stored);
    assert(gm_sparse_store_exclusive(&m, base, desired, 16, &monitor, &stored) == GM_OK && !stored);
    assert(gm_sparse_load_exclusive(&m, base, previous, 16, &monitor) == GM_OK);
    assert(gm_sparse_write(&m, base + 32, desired, 16) == GM_OK);
    assert(gm_sparse_store_exclusive(&m, base, desired, 16, &monitor, &stored) == GM_OK && !stored);
    assert(gm_sparse_protect(&m, base, PAGE, GM_READ) == GM_OK);
    memset(previous, 0xa5, 16);
    assert(gm_sparse_compare_exchange(&m, base, desired, initial, previous, 16) == GM_PROTECTION);
    for (unsigned i = 0; i < 16; ++i) assert(((unsigned char *)previous)[i] == 0xa5);
    uint64_t old = 123;
    assert(gm_sparse_atomic(&m, base + PAGE, 8, GM_ATOMIC_ADD, 1, &old) == GM_NOMEM && old == 123);
    assert(gm_sparse_atomic(&m, base, 8, (GMSparseAtomic)-1, 1, &old) == GM_INVALID);
    assert(gm_sparse_atomic(&m, base + 1, 8, GM_ATOMIC_ADD, 1, &old) == GM_INVALID);
    assert(gm_sparse_atomic(&m, base, 3, GM_ATOMIC_ADD, 1, &old) == GM_INVALID);
    gm_sparse_destroy(&m);
}
static void exclusive_page_isolation(void) {
    GMSparseMemory m={0};
    assert(initialize(&m,base,3*PAGE,3*PAGE)==GM_OK);
    assert(gm_sparse_map(&m,base,3*PAGE,3,3,false)==GM_OK);
    GMSparseExclusive monitor={0};uint64_t value=0,desired=41;bool stored=false;
    // First-write allocation on another page does not break this monitor.
    assert(gm_sparse_load_exclusive(&m,base,&value,8,&monitor)==GM_OK && !value);
    assert(gm_sparse_write(&m,base+PAGE,&desired,8)==GM_OK);
    assert(gm_sparse_prepare(&m,base,8,GM_WRITE)==GM_OK);
    assert(gm_sparse_store_exclusive(&m,base,&desired,8,&monitor,&stored)==GM_OK && stored);
    for(unsigned i=0;i<1000;i++) {
        assert(gm_sparse_load_exclusive(&m,base,&value,8,&monitor)==GM_OK);
        uint64_t old;
        assert(gm_sparse_atomic(&m,base+PAGE,8,GM_ATOMIC_ADD,1,&old)==GM_OK);
        desired=value+1;
        assert(gm_sparse_store_exclusive(&m,base,&desired,8,&monitor,&stored)==GM_OK && stored);
    }
    // Writes crossing into the monitored page invalidate it, even if the
    // write starts in a different page. Failed writes do not invalidate it.
    assert(gm_sparse_load_exclusive(&m,base+PAGE,&value,8,&monitor)==GM_OK);
    uint64_t pair[2]={11,12};
    assert(gm_sparse_write(&m,base+PAGE-8,pair,sizeof pair)==GM_OK);
    assert(gm_sparse_store_exclusive(&m,base+PAGE,&desired,8,&monitor,&stored)==GM_OK && !stored);
    assert(gm_sparse_load_exclusive(&m,base,&value,8,&monitor)==GM_OK);
    assert(gm_sparse_write(&m,base+3*PAGE,&desired,8)!=GM_OK);
    assert(gm_sparse_store_exclusive(&m,base,&desired,8,&monitor,&stored)==GM_OK && stored);
    // Reusing the same virtual address/backing page must not revive a monitor.
    assert(gm_sparse_load_exclusive(&m,base,&value,8,&monitor)==GM_OK);
    assert(gm_sparse_unmap(&m,base,PAGE)==GM_OK);
    assert(gm_sparse_map(&m,base,PAGE,3,3,false)==GM_OK);
    assert(gm_sparse_store_exclusive(&m,base,&desired,8,&monitor,&stored)==GM_OK && !stored);
    assert(gm_sparse_load_exclusive(&m,base,&value,8,&monitor)==GM_OK);
    assert(gm_sparse_protect(&m,base,PAGE,GM_READ)==GM_OK);
    assert(gm_sparse_store_exclusive(&m,base,&desired,8,&monitor,&stored)==GM_OK && !stored);
    gm_sparse_destroy(&m);
}
static void *atomic_worker(void *raw) {
    Worker *w = raw;
    for (unsigned i = 0; i < 10000; ++i) {
        uint64_t previous;
        assert(gm_sparse_atomic(w->memory, base, 8, GM_ATOMIC_ADD, 1, &previous) == GM_OK);
        // Independent CAS counter contends with the same other workers.
        uint64_t expected = 0, desired;
        do {
            desired = expected + 1;
            assert(gm_sparse_compare_exchange(w->memory, base + 8, &expected, &desired, &previous, 8) == GM_OK);
            if (previous == expected) break;
            expected = previous;
        } while (true);
        GMSparseExclusive monitor = {0}; bool stored;
        do {
            assert(gm_sparse_load_exclusive(w->memory, base + 16, &previous, 8, &monitor) == GM_OK);
            desired = previous + 1;
            assert(gm_sparse_store_exclusive(w->memory, base + 16, &desired, 8, &monitor, &stored) == GM_OK);
        } while (!stored);
    }
    return NULL;
}
static void concurrent_atomics(void) {
    GMSparseMemory m = {0};
    assert(initialize(&m, base, PAGE, PAGE) == GM_OK);
    assert(gm_sparse_map(&m, base, PAGE, 3, 3, false) == GM_OK);
    pthread_t threads[8]; Worker workers[8];
    for (unsigned i = 0; i < 8; ++i) {
        workers[i] = (Worker){&m, i};
        assert(!pthread_create(&threads[i], NULL, atomic_worker, &workers[i]));
    }
    for (unsigned i = 0; i < 8; ++i) assert(!pthread_join(threads[i], NULL));
    uint64_t counters[3];
    assert(gm_sparse_read(&m, base, counters, sizeof counters) == GM_OK);
    for (unsigned i = 0; i < 3; ++i) assert(counters[i] == 80000);
    gm_sparse_destroy(&m);
}
static void malformed_and_limits(void) {
    GMSparseMemory m = {0}; uint64_t a;
    assert(initialize(&m, 0, PAGE, PAGE) == GM_INVALID);
    assert(initialize(&m, base, UINT64_MAX, PAGE) == GM_INVALID);
    assert(initialize(&m, base, GIB, PAGE - 1) == GM_INVALID);
    assert(initialize(&m, base, GIB, PAGE) == GM_OK);
    assert(initialize(&m, base, GIB, PAGE) == GM_INVALID);
    assert(gm_sparse_map(&m, base + 1, PAGE, 3, 3, false) == GM_INVALID);
    assert(gm_sparse_map(&m, base, PAGE, 4, 3, false) == GM_INVALID);
    assert(gm_sparse_map(&m, UINT64_MAX - PAGE + 1, PAGE, 3, 3, false) == GM_INVALID);
    assert(gm_sparse_find_free(&m, 2 * GIB, &a) == GM_NOMEM);
    assert(gm_sparse_find_free(&m, PAGE, NULL) == GM_INVALID);
    assert(gm_sparse_read(&m, base, NULL, 1) == GM_INVALID);
    for (unsigned i = 0; i < 256; ++i)
        assert(gm_sparse_map(&m, base + i * 2 * PAGE, PAGE, 3, 3, false) == GM_OK);
    assert(gm_sparse_map(&m, base + 512 * PAGE, PAGE, 3, 3, false) == GM_NOMEM);
    assert(gm_sparse_stats(&m).regions == 256);
    gm_sparse_destroy(&m); gm_sparse_destroy(&m);
}
int main(void) {
    for(unsigned layout=0;layout<2;layout++) {
        initialize=layout?gm_sparse_init_blocks:gm_sparse_init;
        write_statistics();
        aligned_reservations();
    large_reservations(); exhaustion_and_recycling(); reference_comparison();
        concurrent_pages(); atomic_operations(); exclusive_page_isolation(); concurrent_atomics(); malformed_and_limits();
    }
    puts("PASS: 112 GiB sparse reservations, independent reference comparison, atomic failures, recycling and concurrent pages");
}
