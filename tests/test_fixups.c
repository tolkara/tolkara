#include "GuestFixups.h"
#include <mach-o/fixup-chains.h>
#include <stdint.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static bool resolve(const char *name, int ordinal, bool weak, bool lazy, uint64_t *value, void *context) {
    (void)context; (void)weak; (void)lazy;
    assert(!strcmp(name, "_sample") && ordinal == 1);
    *value = 0x12340000; return true;
}
static unsigned recorded; static bool recorded_lazy[4];
// Which kind of bind each call came from, in order.
static bool record(const char *name, int ordinal, bool weak, bool lazy, uint64_t *value, void *context) {
    (void)name; (void)ordinal; (void)weak; (void)context;
    if (recorded < 4) recorded_lazy[recorded] = lazy;
    recorded++; *value = 0x12340000; return true;
}
// What the observer saw, in order: "" for a rebase, else the import name,
// which lives only during the call.
static unsigned observed; static uint64_t observed_at[4], observed_value[4]; static char observed_name[4][16];
static void observe(uint64_t address, uint64_t value, const char *symbol, void *context) {
    (void)context;
    if (observed < 4) {
        observed_at[observed] = address; observed_value[observed] = value;
        snprintf(observed_name[observed], sizeof observed_name[observed], "%s", symbol ? symbol : "");
    }
    observed++;
}
static void setup(GuestImage *i, const uint8_t *r, size_t rn, const uint8_t *b, size_t bn) {
    *i = (GuestImage){0}; i->segment_count = 1; i->dylib_count = 1;
    i->mapped_size = GM_PAGE_SIZE;
    i->segments[0] = (GISegment){.address=0x100000000, .size=GM_PAGE_SIZE, .file_size=GM_PAGE_SIZE, .prot=3};
    assert(gm_map(&i->memory, 0x100000000, GM_PAGE_SIZE, 3, 7, false, false) == GM_OK);
    i->rebase_offset=256; i->rebase_size=(uint32_t)rn;
    i->bind_offset=512; i->bind_size=(uint32_t)bn;
    assert(gm_populate(&i->memory, 0x100000100, r, rn) == GM_OK);
    assert(gm_populate(&i->memory, 0x100000200, b, bn) == GM_OK);
    uint64_t pointer = 0x100000800;
    assert(gm_populate(&i->memory, 0x100000000, &pointer, 8) == GM_OK);
}
static size_t put_uleb(uint8_t *out, uint64_t value) {
    size_t size = 0;
    do {
        uint8_t byte = value & 0x7f; value >>= 7;
        out[size++] = byte | (value ? 0x80 : 0);
    } while (value);
    return size;
}
static void large_rebases(void) {
    // A real large image can exceed a million pointers in one opcode or
    // cumulatively. The source stream is in a separate read-only segment.
    const uint64_t count = 1000001, base = 0x100000000;
    uint64_t bytes = (count * 8 + GM_PAGE_SIZE - 1) & ~(uint64_t)(GM_PAGE_SIZE - 1);
    for (unsigned split = 0; split < 2; split++) {
        GuestImage image = {0}; GFStats stats; char error[256]; uint64_t value;
        image.segment_count = 2; image.mapped_size = bytes + GM_PAGE_SIZE;
        image.segments[0] = (GISegment){.address=base, .size=bytes, .file_size=bytes, .prot=3};
        image.segments[1] = (GISegment){.address=base+bytes, .size=GM_PAGE_SIZE,
            .file_offset=bytes, .file_size=GM_PAGE_SIZE, .prot=1};
        assert(gm_map(&image.memory, base, bytes, 3, 3, false, false) == GM_OK);
        assert(gm_map(&image.memory, base+bytes, GM_PAGE_SIZE, 1, 1, false, false) == GM_OK);
        uint8_t stream[32] = {0x11, 0x20, 0, 0x60};
        size_t length = 4;
        length += put_uleb(stream+length, split ? 600000 : count);
        if (split) { stream[length++] = 0x60; length += put_uleb(stream+length, count-600000); }
        stream[length++] = 0;
        image.rebase_offset = (uint32_t)bytes; image.rebase_size = (uint32_t)length;
        assert(gm_populate(&image.memory, base+bytes, stream, length) == GM_OK);
        assert(gf_apply(&image, 0x200000, resolve, NULL, &stats, error, sizeof error));
        assert(stats.rebases == count && stats.binds == 0);
        assert(gm_read(&image.memory, base, &value, 8) == GM_OK && value == 0x200000);
        assert(gm_read(&image.memory, base+(count-1)*8, &value, 8) == GM_OK && value == 0x200000);
        gi_destroy(&image);
    }
    // Repeatedly resetting to a valid slot cannot evade the image-sized work
    // budget. Reject the next operation without writing that pointer again.
    size_t limit = GM_PAGE_SIZE / 8, length = 1;
    uint8_t *stream = malloc(4*(limit+1)+2); assert(stream);
    stream[0] = 0x11;
    for (size_t n = 0; n <= limit; n++) {
        stream[length++] = 0x20; stream[length++] = 0; stream[length++] = 0x51;
    }
    stream[length++] = 0;
    GuestImage image; GFStats stats; char error[256]; uint64_t value;
    setup(&image, stream, length, NULL, 0);
    assert(!gf_apply(&image, 1, resolve, NULL, &stats, error, sizeof error));
    assert(stats.rebases == limit && strstr(error, "rebase count exceeds image pointer budget"));
    assert(gm_read(&image.memory, 0x100000000, &value, 8) == GM_OK && value == 0x100000800+limit);
    gi_destroy(&image); free(stream);
    // A huge repeat is refused before any pointer is touched.
    uint8_t huge[16] = {0x11, 0x20, 0, 0x60}; length = 4;
    length += put_uleb(huge+length, UINT64_MAX); huge[length++] = 0;
    setup(&image, huge, length, NULL, 0);
    assert(!gf_apply(&image, 1, resolve, NULL, &stats, error, sizeof error));
    assert(stats.rebases == 0 && strstr(error, "rebase count exceeds image pointer budget"));
    assert(gm_read(&image.memory, 0x100000000, &value, 8) == GM_OK && value == 0x100000800);
    gi_destroy(&image);
}
// One page, one import, one chain, built by hand.
static size_t chained_blob(uint8_t *out, uint16_t format) {
    memset(out, 0, 128);
    uint32_t header[7] = {0, 32, 64, 80, 1, DYLD_CHAINED_IMPORT, 0};
    memcpy(out, header, sizeof header);
    uint32_t starts[2] = {1, 8};                    // one segment, its info eight bytes on
    memcpy(out + 32, starts, sizeof starts);
    uint32_t size = 24;
    uint16_t page_size = GM_PAGE_SIZE, page_count = 1, page_start = 0;
    uint64_t segment_offset = 0;
    memcpy(out + 40, &size, 4);
    memcpy(out + 44, &page_size, 2);
    memcpy(out + 46, &format, 2);
    memcpy(out + 48, &segment_offset, 8);
    memcpy(out + 60, &page_count, 2);
    memcpy(out + 62, &page_start, 2);
    uint32_t import = 1;                            // library ordinal one, name at zero
    memcpy(out + 64, &import, 4);
    memcpy(out + 80, "_sample", 8);
    return 88;
}
static void chained_setup(GuestImage *i, uint16_t format, uint64_t first, uint64_t second) {
    *i = (GuestImage){0}; i->segment_count = 1; i->dylib_count = 1;
    i->segments[0] = (GISegment){.address=0x100000000, .size=GM_PAGE_SIZE, .file_size=GM_PAGE_SIZE, .prot=3};
    assert(gm_map(&i->memory, 0x100000000, GM_PAGE_SIZE, 3, 7, false, false) == GM_OK);
    i->header_address = 0x100000000; i->mapped_size = GM_PAGE_SIZE;
    i->chained_fixups = true; i->chained_offset = 1024;
    uint8_t blob[128];
    i->chained_size = (uint32_t)chained_blob(blob, format);
    assert(gm_populate(&i->memory, 0x100000400, blob, i->chained_size) == GM_OK);
    assert(gm_populate(&i->memory, 0x100000000, &first, 8) == GM_OK);
    assert(gm_populate(&i->memory, 0x100000008, &second, 8) == GM_OK);
}

int main(void) {
    large_rebases();
    GuestImage i; GFStats stats; char error[256]; uint64_t value;
    const uint8_t r[] = {0x11,0x20,0,0x51,0};
    const uint8_t b[] = {0x11,0x40,'_','s','a','m','p','l','e',0,0x70,8,0x60,0x7c,0x90,0};
    setup(&i,r,sizeof r,b,sizeof b);
    assert(gf_apply(&i,0x200000,resolve,NULL,&stats,error,sizeof error));
    assert(stats.rebases==1 && stats.binds==1);
    assert(gm_read(&i.memory,0x100000000,&value,8)==GM_OK && value==0x100200800);
    assert(gm_read(&i.memory,0x100000008,&value,8)==GM_OK && value==0x1233fffc);
    gi_destroy(&i);
    // The same fixups observed: every written pointer, rebases unnamed.
    setup(&i,r,sizeof r,b,sizeof b); observed=0;
    assert(gf_apply_observed(&i,0x200000,resolve,NULL,observe,NULL,&stats,error,sizeof error) && observed==2);
    assert(observed_at[0]==0x100000000 && observed_value[0]==0x100200800 && !observed_name[0][0]);
    assert(observed_at[1]==0x100000008 && observed_value[1]==0x1233fffc && !strcmp(observed_name[1],"_sample"));
    gi_destroy(&i);
    // A lazy and a plain bind: lazy is bound first.
    const uint8_t lazy_stream[]={0x70,16,0x11,0x40,'_','s','a','m','p','l','e',0,0x90,0};
    setup(&i,r,sizeof r,b,sizeof b);
    assert(gm_populate(&i.memory,0x100000300,lazy_stream,sizeof lazy_stream)==GM_OK);
    i.lazy_bind_offset=768; i.lazy_bind_size=sizeof lazy_stream;
    recorded=0;
    assert(gf_apply(&i,0,record,NULL,&stats,error,sizeof error) && stats.binds==2);
    assert(recorded==2 && recorded_lazy[0] && !recorded_lazy[1]);
    gi_destroy(&i);
    // Vivox uses DO_BIND_ADD_ADDR_ULEB with -8, so the next bind is at the
    // same location. Unsigned wrap is dyld stream arithmetic, not an overflow.
    const uint8_t bind_backwards[]={0x11,0x40,'_','s','a','m','p','l','e',0,0x70,8,
        0xa0,0xf8,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,1,0x90,0};
    setup(&i,r,sizeof r,bind_backwards,sizeof bind_backwards);
    assert(gf_apply(&i,0,resolve,NULL,&stats,error,sizeof error) && stats.binds==2);
    assert(gm_read(&i.memory,0x100000008,&value,8)==GM_OK && value==0x12340000);
    gi_destroy(&i);
    // Real dyld streams use a wrapping ULEB delta to move backward.
    const uint8_t backwards[]={0x11,0x40,'_','s','a','m','p','l','e',0,0x70,16,0x90,
        0x80,0xe8,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,1,0x90,0};
    setup(&i,r,sizeof r,backwards,sizeof backwards);
    assert(gf_apply(&i,0,resolve,NULL,&stats,error,sizeof error) && stats.binds==2);
    assert(gm_read(&i.memory,0x100000000,&value,8)==GM_OK && value==0x12340000);
    gi_destroy(&i);
    // Lazy DONE separates independent records; state cannot leak across them.
    const uint8_t bad_lazy[]={0x11,0x40,'_','s','a','m','p','l','e',0,0x70,8,0x90,0,0x90,0};
    setup(&i,r,sizeof r,bad_lazy,sizeof bad_lazy);
    i.lazy_bind_offset=i.bind_offset; i.lazy_bind_size=i.bind_size; i.bind_size=0;
    assert(!gf_apply(&i,0,resolve,NULL,&stats,error,sizeof error)); gi_destroy(&i);
    // Truncated ULEB, overflowing ULEB, invalid segment, out-of-range pointer,
    // and enormous repeat count must fail without reading beyond the stream.
    const uint8_t invalid[][16] = {{0x20,0x80},{0x20,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,2},
        {0x11,0x2f,0,0x51,0},{0x11,0x20,0xff,0x7f,0x51,0},{0x11,0x20,0,0x60,0xff,0xff,0xff,0x7f,0}};
    const size_t sizes[]={2,11,5,7,9};
    for(size_t n=0;n<5;n++) { setup(&i,invalid[n],sizes[n],b,sizeof b);
        assert(!gf_apply(&i,0,resolve,NULL,&stats,error,sizeof error)); gi_destroy(&i); }
    setup(&i,r,sizeof r,b,sizeof b-1);
    assert(!gf_apply(&i,0,resolve,NULL,&stats,error,sizeof error)); gi_destroy(&i);
    {
        // A rebase to the next slot, then a bind.
        uint64_t rebase = 0x100000800ULL | (2ULL << 51), bind = (1ULL << 63) | (8ULL << 24);
        chained_setup(&i, DYLD_CHAINED_PTR_64, rebase, bind);
        assert(gf_apply(&i, 0x200000, resolve, NULL, &stats, error, sizeof error));
        assert(stats.rebases == 1 && stats.binds == 1);
        assert(gm_read(&i.memory, 0x100000000, &value, 8) == GM_OK && value == 0x100200800);
        assert(gm_read(&i.memory, 0x100000008, &value, 8) == GM_OK && value == 0x12340008);
        gi_destroy(&i);
        // Observed, a chain reports each pointer as it is written.
        chained_setup(&i, DYLD_CHAINED_PTR_64, rebase, bind); observed = 0;
        assert(gf_apply_observed(&i, 0x200000, resolve, NULL, observe, NULL, &stats, error, sizeof error) && observed == 2);
        assert(observed_at[0] == 0x100000000 && observed_value[0] == 0x100200800 && !observed_name[0][0]);
        assert(observed_at[1] == 0x100000008 && observed_value[1] == 0x12340008 && !strcmp(observed_name[1], "_sample"));
        gi_destroy(&i);

        // The same chain written as offsets from the image base.
        chained_setup(&i, DYLD_CHAINED_PTR_64_OFFSET, 0x800ULL | (2ULL << 51), bind);
        assert(gf_apply(&i, 0x200000, resolve, NULL, &stats, error, sizeof error));
        assert(gm_read(&i.memory, 0x100000000, &value, 8) == GM_OK && value == 0x100200800);
        gi_destroy(&i);
        // Offsets again, from a page start past zero: a rebase, then a bind
        // with an inline addend of four. The words before it stay as they were.
        chained_setup(&i, DYLD_CHAINED_PTR_64_OFFSET, 0, 0);
        uint16_t page_start = 0x100;
        uint64_t chain[2] = {0x800ULL | (2ULL << 51), (1ULL << 63) | (4ULL << 24)};
        assert(gm_populate(&i.memory, 0x10000043E, &page_start, sizeof page_start) == GM_OK);
        assert(gm_populate(&i.memory, 0x100000100, chain, sizeof chain) == GM_OK);
        assert(gf_apply(&i, 0x200000, resolve, NULL, &stats, error, sizeof error) && stats.rebases == 1 && stats.binds == 1);
        assert(gm_read(&i.memory, 0x100000100, &value, 8) == GM_OK && value == 0x100200800);
        assert(gm_read(&i.memory, 0x100000108, &value, 8) == GM_OK && value == 0x12340004);
        assert(gm_read(&i.memory, 0x100000000, &value, 8) == GM_OK && value == 0);
        gi_destroy(&i);
        // A vmaddr rebase's high8 lands in the top byte.
        chained_setup(&i, DYLD_CHAINED_PTR_64, 0x100000800ULL | (0x5AULL << 36), 0);
        assert(gf_apply(&i, 0x200000, resolve, NULL, &stats, error, sizeof error) && stats.rebases == 1);
        assert(gm_read(&i.memory, 0x100000000, &value, 8) == GM_OK && value == (0x100200800ULL | (0x5AULL << 56)));
        gi_destroy(&i);

        // Two pointer initializers in a chain: read after fixups.
        chained_setup(&i, DYLD_CHAINED_PTR_64, 0x100000800ULL | (2ULL << 51), 0x100000900ULL);
        i.initializer_address = 0x100000000; i.initializer_count = 2;
        uint64_t record = 0;
        assert(gm_read(&i.memory, 0x100000000, &record, 8) == GM_OK);
        assert(gf_apply(&i, 0x200000, resolve, NULL, &stats, error, sizeof error) && stats.rebases == 2);
        uint64_t placed[2];
        assert(gm_read(&i.memory, 0x100000000, placed, sizeof placed) == GM_OK);
        uint64_t at = (uintptr_t)placed - i.initializer_address;
        assert(gi_placed_initializer(&i, at, 0) == 0x100200800 && gi_placed_initializer(&i, at, 1) == 0x100200900);
        assert(record + 0x200000 != 0x100200800);
        gi_destroy(&i);

        // Malformed chains are refused rather than followed.
        chained_setup(&i, 99, rebase, bind);
        assert(!gf_apply(&i, 0, resolve, NULL, &stats, error, sizeof error) && strstr(error, "pointer format"));
        gi_destroy(&i);
        chained_setup(&i, DYLD_CHAINED_PTR_64, rebase, (1ULL << 63) | 5);
        assert(!gf_apply(&i, 0, resolve, NULL, &stats, error, sizeof error) && strstr(error, "import 5"));
        gi_destroy(&i);
        // arm64e pointers are authenticated; only plain formats are walked.
        chained_setup(&i, DYLD_CHAINED_PTR_ARM64E, rebase, bind);
        assert(!gf_apply(&i, 0, resolve, NULL, &stats, error, sizeof error) && strstr(error, "pointer format"));
        gi_destroy(&i);
        // The first ordinal past the table.
        chained_setup(&i, DYLD_CHAINED_PTR_64, rebase, bind | 1);
        assert(!gf_apply(&i, 0, resolve, NULL, &stats, error, sizeof error) && strstr(error, "import 1 of 1"));
        gi_destroy(&i);
        // An import count the blob cannot hold, and a name past the blob's end.
        chained_setup(&i, DYLD_CHAINED_PTR_64, rebase, bind);
        uint32_t huge = 0x1000000;
        assert(gm_populate(&i.memory, 0x100000410, &huge, sizeof huge) == GM_OK);
        assert(!gf_apply(&i, 0, resolve, NULL, &stats, error, sizeof error) && strstr(error, "imports outside"));
        gi_destroy(&i);
        chained_setup(&i, DYLD_CHAINED_PTR_64, rebase, bind);
        uint32_t unnamed = 1 | (200u << 9);
        assert(gm_populate(&i.memory, 0x100000440, &unnamed, sizeof unnamed) == GM_OK);
        assert(!gf_apply(&i, 0, resolve, NULL, &stats, error, sizeof error) && strstr(error, "names nothing"));
        gi_destroy(&i);
        // A chain that walks off the end of its page.
        chained_setup(&i, DYLD_CHAINED_PTR_64, 4094ULL << 51, bind);
        uint64_t tail = 1ULL << 51;
        assert(gm_populate(&i.memory, 0x100003FF8, &tail, 8) == GM_OK);
        assert(!gf_apply(&i, 0, resolve, NULL, &stats, error, sizeof error) && strstr(error, "leaves its page"));
        gi_destroy(&i);
        // Starts for a segment the image does not have: two listed, the second used.
        chained_setup(&i, DYLD_CHAINED_PTR_64, rebase, bind);
        uint32_t two_segments[3] = {2, 0, 8};
        assert(gm_populate(&i.memory, 0x100000420, two_segments, sizeof two_segments) == GM_OK);
        assert(!gf_apply(&i, 0, resolve, NULL, &stats, error, sizeof error) && strstr(error, "segment 1 of 1"));
        gi_destroy(&i);
        // An import naming a library the image does not list, or an unknown special.
        for (unsigned k = 0; k < 2; k++) {
            chained_setup(&i, DYLD_CHAINED_PTR_64, rebase, bind);
            uint32_t import = k ? 0xF1 : 2;
            assert(gm_populate(&i.memory, 0x100000440, &import, sizeof import) == GM_OK);
            assert(!gf_apply(&i, 0, resolve, NULL, &stats, error, sizeof error) && strstr(error, "invalid chained import ordinal"));
            gi_destroy(&i);
        }
        // A page past the end of its segment.
        chained_setup(&i, DYLD_CHAINED_PTR_64, rebase, bind);
        uint64_t beyond = GM_PAGE_SIZE;
        assert(gm_populate(&i.memory, 0x100000430, &beyond, sizeof beyond) == GM_OK);
        assert(!gf_apply(&i, 0, resolve, NULL, &stats, error, sizeof error) && strstr(error, "outside segment"));
        gi_destroy(&i);
        // Reserved bits set in a rebase or a bind, at either end of their range.
        const uint64_t reserved[][2] = {{rebase | (1ULL << 44), bind}, {rebase | (1ULL << 50), bind},
                                        {rebase, bind | (1ULL << 32)}, {rebase, bind | (1ULL << 50)}};
        for (size_t k = 0; k < sizeof reserved / sizeof *reserved; k++) {
            chained_setup(&i, DYLD_CHAINED_PTR_64, reserved[k][0], reserved[k][1]);
            assert(!gf_apply(&i, 0, resolve, NULL, &stats, error, sizeof error) && strstr(error, "reserved bits"));
            gi_destroy(&i);
        }
        // The bits beside those ranges still decode: a full high8 and a full
        // inline addend below them, and above them an odd next (bit 51), as a
        // pointer aligned to four bytes only has. The chain starts at 0x100.
        chained_setup(&i, DYLD_CHAINED_PTR_64, 0, 0);
        const uint16_t edge_start = 0x100;
        const uint64_t edge_rebase = 0x100000800ULL | (0xFFULL << 36) | (3ULL << 51);
        const uint64_t edge_bind = (1ULL << 63) | (0xFFULL << 24) | (3ULL << 51), edge_last = 0x100000900ULL;
        assert(gm_populate(&i.memory, 0x10000043E, &edge_start, sizeof edge_start) == GM_OK);
        assert(gm_populate(&i.memory, 0x100000100, &edge_rebase, 8) == GM_OK);
        assert(gm_populate(&i.memory, 0x10000010C, &edge_bind, 8) == GM_OK);
        assert(gm_populate(&i.memory, 0x100000118, &edge_last, 8) == GM_OK);
        assert(gf_apply(&i, 0x200000, resolve, NULL, &stats, error, sizeof error) && stats.rebases == 2 && stats.binds == 1);
        assert(gm_read(&i.memory, 0x100000100, &value, 8) == GM_OK && value == (0x100200800ULL | (0xFFULL << 56)));
        assert(gm_read(&i.memory, 0x10000010C, &value, 8) == GM_OK && value == 0x123400FF);
        assert(gm_read(&i.memory, 0x100000118, &value, 8) == GM_OK && value == 0x100200900);
        gi_destroy(&i);
        // Chained fixups beside any dyld info opcode stream.
        for (unsigned k = 0; k < 4; k++) {
            chained_setup(&i, DYLD_CHAINED_PTR_64, rebase, bind);
            uint32_t *sizes[] = {&i.rebase_size, &i.bind_size, &i.lazy_bind_size, &i.weak_bind_size};
            *sizes[k] = 4;
            assert(!gf_apply(&i, 0, resolve, NULL, &stats, error, sizeof error) && strstr(error, "dyld info opcodes"));
            assert(stats.rebases == 0 && stats.binds == 0);
            gi_destroy(&i);
        }
    }
    puts("PASS: Mach-O pointer relocation, import binding, signed addends, observed fixups, malformed fixup bounds");
    puts("PASS: lazy binds first, chained fixups, chained initializers read after fixups, malformed chains");
    puts("PASS: large rebase streams and image-sized work budget, including repeated targets and huge counts");
}
