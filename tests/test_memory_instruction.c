#include "GuestMemoryInstruction.h"
#include "SparseMemoryProbe.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static const uint64_t base = UINT64_C(0x10000000000);
extern uint64_t gm_sparse_probe_program(void *, uint64_t, void *);
extern const unsigned char gm_memory_atomic_references[], gm_memory_atomic_references_end[];
extern const unsigned char gm_memory_structure_references[], gm_memory_structure_references_end[];
extern uintptr_t gm_memory_structure_call(const void *, void *, uintptr_t, void *);
static void native_structure_comparison(void) {
    GMSparseMemory m={0};
    assert(gm_sparse_init(&m,base,2*GM_PAGE_SIZE,2*GM_PAGE_SIZE)==GM_OK);
    assert(gm_sparse_map(&m,base,2*GM_PAGE_SIZE,3,3,false)==GM_OK);
    size_t count=(size_t)(gm_memory_structure_references_end-gm_memory_structure_references)/8;
    assert(count==164);
    uint32_t first,replicate;
    memcpy(&first,gm_memory_structure_references,4);
    memcpy(&replicate,gm_memory_structure_references_end-8,4);
    const uint32_t invalid[]={first|(1u<<21),first|(1u<<16),
        (first&~(15u<<12))|(15u<<12),replicate&~(1u<<22)};
    for(unsigned n=0;n<sizeof invalid/sizeof *invalid;n++) {
        GMMemoryRegisters r={0};r.pc=0x4000;r.x[0]=base;memset(r.vector,0x91,sizeof r.vector);
        GMMemoryRegisters before=r;GMResult fault;
        assert(gm_memory_step(&m,invalid[n],&r,&fault)==GM_STEP_UNSUPPORTED);
        assert(!memcmp(&r,&before,sizeof r));
    }
    for(size_t n=0;n<count;n++)for(unsigned seed=0;seed<3;seed++)for(unsigned skew=0;skew<2;skew++) {
        const unsigned char *code=gm_memory_structure_references+n*8;
        uint32_t instruction;memcpy(&instruction,code,4);
        unsigned char host[128],actual[128],vectors[96];
        for(unsigned j=0;j<sizeof host;j++)host[j]=(unsigned char)(j*13+seed*71);
        for(unsigned j=0;j<sizeof vectors;j++)vectors[j]=(unsigned char)(j*19+seed*23);
        GMMemoryRegisters r={0};GMResult fault;
        r.pc=0x4000;r.x[0]=base+GM_PAGE_SIZE-32+skew*3;r.x[1]=17;
        memcpy(r.vector,vectors,64);memcpy(r.vector[30],vectors+64,32);
        assert(gm_sparse_write(&m,base+GM_PAGE_SIZE-32,host,sizeof host)==GM_OK);
        uintptr_t result=gm_memory_structure_call(code,host+skew*3,17,vectors);
        assert(gm_memory_step(&m,instruction,&r,&fault)==GM_STEP_OK);
        assert(r.x[0]-(base+GM_PAGE_SIZE-32)==result-(uintptr_t)host && r.pc==0x4004 && r.x[1]==17);
        assert(!memcmp(r.vector,vectors,64) && !memcmp(r.vector[30],vectors+64,32));
        assert(gm_sparse_read(&m,base+GM_PAGE_SIZE-32,actual,sizeof actual)==GM_OK);
        assert(!memcmp(actual,host,sizeof actual));
        // No access or writeback may partially retire when permissions fail.
        assert(gm_sparse_protect(&m,base+GM_PAGE_SIZE,GM_PAGE_SIZE,0)==GM_OK);
        r.x[0]=base+GM_PAGE_SIZE;GMMemoryRegisters before=r;
        assert(gm_memory_step(&m,instruction,&r,&fault)==GM_STEP_FAULT && fault==GM_PROTECTION);
        assert(!memcmp(&r,&before,sizeof r));
        assert(gm_sparse_protect(&m,base+GM_PAGE_SIZE,GM_PAGE_SIZE,3)==GM_OK);
        assert(gm_sparse_read(&m,base+GM_PAGE_SIZE-32,actual,sizeof actual)==GM_OK);
        assert(!memcmp(actual,host,sizeof actual));
    }
    gm_sparse_destroy(&m);
    puts("PASS: 164 SIMD structure encodings match native loads/stores, lanes, replication, wrap, post-index and fault atomicity");
}
static void native_atomic_comparison(void) {
    GMSparseMemory m = {0};
    assert(gm_sparse_init(&m, base, GM_PAGE_SIZE, GM_PAGE_SIZE) == GM_OK);
    assert(gm_sparse_map(&m, base, GM_PAGE_SIZE, 3, 3, false) == GM_OK);
    assert(gm_memory_atomic_references_end - gm_memory_atomic_references == 36 * 8);
    const uint64_t inputs[] = {0, 1, UINT64_MAX, 0x80, 0x8000, 0x80000000,
        UINT64_C(0x8000000000000000), UINT64_C(0xa5b673920cfedb18)};
    for (unsigned instruction_index = 0; instruction_index < 36; ++instruction_index) {
        const void *code = gm_memory_atomic_references + instruction_index * 8;
        uint64_t (*reference)(uint64_t *, uint64_t) = (uint64_t (*)(uint64_t *, uint64_t))code;
        uint32_t instruction;
        memcpy(&instruction, code, sizeof instruction);
        for (unsigned a = 0; a < 8; ++a) for (unsigned b = 0; b < 8; ++b) {
            uint64_t native_value = inputs[a], result = reference(&native_value, inputs[b]);
            GMMemoryRegisters r = {0}; GMResult fault;
            r.pc = 0x4000; r.x[0] = base; r.x[1] = inputs[b];
            assert(gm_sparse_write(&m, base, &inputs[a], 8) == GM_OK);
            assert(gm_memory_step(&m, instruction, &r, &fault) == GM_STEP_OK);
            assert(r.x[0] == result && r.x[1] == inputs[b] && r.pc == 0x4004);
            uint64_t software_value;
            assert(gm_sparse_read(&m, base, &software_value, 8) == GM_OK);
            assert(software_value == native_value);
        }
    }
    gm_sparse_destroy(&m);
}
static void scalar_and_vector(void) {
    GMSparseMemory m = {0};
    assert(gm_sparse_init(&m, base, 4 * GM_PAGE_SIZE, 4 * GM_PAGE_SIZE) == GM_OK);
    assert(gm_sparse_map(&m, base, 4 * GM_PAGE_SIZE, 3, 3, false) == GM_OK);
    GMMemoryRegisters r = {0}; GMResult fault;
    r.pc = 0x4000; r.x[1] = base;
    unsigned char pattern[32];
    for (unsigned i = 0; i < sizeof pattern; ++i) pattern[i] = (unsigned char)(0x80 + i);
    assert(gm_sparse_write(&m, base, pattern, sizeof pattern) == GM_OK);
    // Independently specified little-endian/sign-extension results.
    const struct { uint32_t instruction; uint64_t expected; } cases[] = {
        {0x39400020, 0x80}, {0x79400020, 0x8180},
        {0xb9400020, 0x83828180}, {0xf9400020, UINT64_C(0x8786858483828180)},
        {0x39800020, UINT64_C(0xffffffffffffff80)}, {0x39c00020, 0xffffff80},
        {0x79800020, UINT64_C(0xffffffffffff8180)}, {0x79c00020, 0xffff8180},
        {0xb9800020, UINT64_C(0xffffffff83828180)}
    };
    for (unsigned i = 0; i < sizeof cases / sizeof *cases; ++i) {
        r.x[0] = UINT64_MAX;
        assert(gm_memory_step(&m, cases[i].instruction, &r, &fault) == GM_STEP_OK);
        assert(r.x[0] == cases[i].expected && fault == GM_OK);
    }
    // Q, D, S, H and B loads clear the rest of the vector register.
    const uint32_t vector_loads[] = {0x3dc00020, 0xfd400020, 0xbd400020, 0x7d400020, 0x3d400020};
    const unsigned lengths[] = {16, 8, 4, 2, 1};
    for (unsigned i = 0; i < 5; ++i) {
        memset(r.vector[0], 0xff, 16);
        assert(gm_memory_step(&m, vector_loads[i], &r, &fault) == GM_STEP_OK);
        assert(!memcmp(r.vector[0], pattern, lengths[i]));
        for (unsigned j = lengths[i]; j < 16; ++j) assert(r.vector[0][j] == 0);
    }
    // STP with pre-index: a cross-page store updates the base only on success.
    r.x[1] = base + GM_PAGE_SIZE - 16; r.x[0] = 5; r.x[2] = 7;
    uint64_t previous_pc = r.pc;
    assert(gm_memory_step(&m, 0xa9808820, &r, &fault) == GM_STEP_OK); // stp x0,x2,[x1,#8]!
    assert(r.x[1] == base + GM_PAGE_SIZE - 8 && r.pc == previous_pc + 4);
    uint64_t words[2] = {0};
    assert(gm_sparse_read(&m, r.x[1], words, sizeof words) == GM_OK && words[0] == 5 && words[1] == 7);
    assert(gm_sparse_protect(&m, base + GM_PAGE_SIZE, GM_PAGE_SIZE, GM_READ) == GM_OK);
    r.x[1] = base + GM_PAGE_SIZE - 16;
    GMMemoryRegisters before = r;
    assert(gm_memory_step(&m, 0xa9808820, &r, &fault) == GM_STEP_FAULT && fault == GM_PROTECTION);
    assert(!memcmp(&r, &before, sizeof r));
    assert(gm_sparse_read(&m, base + GM_PAGE_SIZE - 8, words, sizeof words) == GM_OK && words[0] == 5 && words[1] == 7);
    const uint32_t refused[] = {0xffffffff, 0xd503201f, 0xf9800020, 0xa9c00020};
    for (unsigned i = 0; i < sizeof refused / sizeof *refused; ++i) {
        assert(gm_memory_step(&m, refused[i], &r, &fault) == GM_STEP_UNSUPPORTED);
        assert(!memcmp(&r, &before, sizeof r));
    }
    r.sp = base + 1;
    assert(gm_memory_step(&m, 0xf94003e0, &r, &fault) == GM_STEP_FAULT && fault == GM_INVALID);
    gm_sparse_destroy(&m);
}
static void native_fixture_reference(void) {
    for (uint64_t seed = 0; seed < 1024; ++seed) {
        uint64_t storage[16] = {0}, vectors[4] = {0};
        uint64_t signed_byte = (seed & 255) < 128 ? seed & 255 : (seed & 255) - 256;
        uint64_t expected = (seed & 255) + (seed & 65535) + (seed & UINT32_MAX) + seed * 3 + signed_byte;
        assert(gm_sparse_probe_program(storage, seed, vectors) == expected);
        for (unsigned i = 0; i < 4; ++i) assert(vectors[i] == seed);
    }
}

static void unaligned_ordered_compatibility(void) {
    GMSparseMemory m = {0};
    assert(gm_sparse_init(&m, base, 2 * GM_PAGE_SIZE, 2 * GM_PAGE_SIZE) == GM_OK);
    assert(gm_sparse_map(&m, base, 2 * GM_PAGE_SIZE, 3, 3, false) == GM_OK);
    for (unsigned scale = 1; scale <= 3; ++scale) {
        unsigned width = 1u << scale;
        for (unsigned skew = 1; skew < width; ++skew) {
            uint64_t address = base + GM_PAGE_SIZE - width + skew;
            unsigned char zero[8] = {0}, bytes[8];
            GMMemoryRegisters r = {0}; GMResult fault;
            r.pc = 0x4000; r.x[1] = address; r.x[0] = UINT64_C(0x8877665544332211);
            GMMemoryRegisters before = r;
            uint32_t store = (scale << 30) | 0x089ffc20;
            assert(gm_sparse_write(&m, address, zero, width) == GM_OK);
            assert(gm_memory_step(&m, store, &r, &fault) == GM_STEP_FAULT && fault == GM_INVALID);
            assert(!memcmp(&r, &before, sizeof r));
            assert(gm_memory_step_x86_ordered(&m, store, &r, &fault) == GM_STEP_OK);
            assert(r.pc == 0x4004);
            assert(gm_sparse_read(&m, address, bytes, width) == GM_OK);
            for (unsigned i = 0; i < width; ++i) assert(bytes[i] == 0x11 * (i + 1));
            const uint32_t loads[] = {(scale << 30) | 0x08dffc20, (scale << 30) | 0x38bfc020};
            for (unsigned i = 0; i < 2; ++i) {
                r.x[0] = 0;
                assert(gm_memory_step_x86_ordered(&m, loads[i], &r, &fault) == GM_STEP_OK);
                uint64_t mask = width == 8 ? UINT64_MAX : (UINT64_C(1) << (width * 8)) - 1;
                assert(r.x[0] == (UINT64_C(0x8877665544332211) & mask));
            }
            assert(gm_sparse_protect(&m, base + GM_PAGE_SIZE, GM_PAGE_SIZE, GM_READ) == GM_OK);
            r.x[0] = 0; before = r;
            assert(gm_memory_step_x86_ordered(&m, store, &r, &fault) == GM_STEP_FAULT && fault == GM_PROTECTION);
            assert(!memcmp(&r, &before, sizeof r));
            assert(gm_sparse_read(&m, address, bytes, width) == GM_OK);
            for (unsigned i = 0; i < width; ++i) assert(bytes[i] == 0x11 * (i + 1));
            assert(gm_sparse_protect(&m, base + GM_PAGE_SIZE, GM_PAGE_SIZE, 0) == GM_OK);
            assert(gm_memory_step_x86_ordered(&m, loads[0], &r, &fault) == GM_STEP_FAULT && fault == GM_PROTECTION);
            assert(!memcmp(&r, &before, sizeof r));
            assert(gm_sparse_protect(&m, base + GM_PAGE_SIZE, GM_PAGE_SIZE, 3) == GM_OK);
        }
    }
    gm_sparse_destroy(&m);
    puts("PASS: opt-in unaligned ordered accesses, cross-page protection and strict default");
}

int main(void) {
    unaligned_ordered_compatibility();
    scalar_and_vector(); native_fixture_reference(); native_atomic_comparison(); native_structure_comparison();
    assert(guest_sparse_memory_probe(stdout));
    puts("PASS: memory-instruction semantics, failure atomicity and native fault/resume fixture");
}
