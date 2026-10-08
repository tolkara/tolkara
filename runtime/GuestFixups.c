#include "GuestFixups.h"
#include <mach-o/fixup-chains.h>
#include <mach-o/loader.h>
#include <stdlib.h>
#include <string.h>

typedef struct { const uint8_t *p, *end; bool bad; } Cursor;
static uint64_t leb(Cursor *c, bool sign) {
    uint64_t value = 0;
    for (unsigned shift = 0; shift < 70; shift += 7) {
        if (c->p == c->end) break;
        uint8_t byte = *c->p++;
        if (shift == 63 && (sign ? ((byte & 0x7f) != 0 && (byte & 0x7f) != 0x7f) : (byte & 0x7e))) break;
        value |= (uint64_t)(byte & 0x7f) << shift;
        if (!(byte & 0x80)) {
            if (sign && shift < 63 && (byte & 0x40)) value |= UINT64_MAX << (shift + 7);
            return value;
        }
    }
    c->bad = true; return 0;
}
static bool add(uint64_t *a, uint64_t b) {
    if (b > UINT64_MAX - *a) return false;
    *a += b; return true;
}
static uint8_t *stream(GuestImage *image, uint32_t offset, uint32_t size) {
    if (size > 32 * 1024 * 1024) return NULL;
    for (size_t i = 0; i < image->segment_count; i++) {
        GISegment *s = &image->segments[i];
        if (offset < s->file_offset || offset - s->file_offset > s->file_size ||
            size > s->file_size - (offset - s->file_offset)) continue;
        uint8_t *bytes = malloc(size);
        if (!bytes) return NULL;
        if (gm_read(&image->memory, s->address + offset - s->file_offset, bytes, size) == GM_OK) return bytes;
        free(bytes); return NULL;
    }
    return NULL;
}
static bool target(GuestImage *image, size_t seg, uint64_t offset, uint64_t *address) {
    if (seg >= image->segment_count) return false;
    GISegment *s = &image->segments[seg];
    if (!s->prot || offset > s->size || 8 > s->size - offset || (offset & 7)) return false;
    *address = s->address + offset; return true;
}
typedef struct { GFObserve observe; void *context; } Observer;
static void notify(const Observer *o, uint64_t address, uint64_t value, const char *symbol) {
    if (o->observe) o->observe(address, value, symbol, o->context);
}
static bool rebases(GuestImage *image, Cursor *c, uint64_t slide, const Observer *o, GFStats *stats,
                    char *error, size_t error_size) {
    size_t seg = SIZE_MAX; uint64_t offset = 0; unsigned type = 0;
    // Large images can legitimately contain more than a million pointers.
    // Bound work by the loaded image, including streams that revisit a slot.
    uint64_t limit = image->mapped_size / sizeof(uint64_t);
    while (c->p < c->end) {
        uint8_t byte = *c->p++, op = byte & 0xf0, imm = byte & 15;
        uint64_t count = 0, skip = 0;
        switch (op) {
        case REBASE_OPCODE_DONE: return true;
        case REBASE_OPCODE_SET_TYPE_IMM: type = imm; break;
        case REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB: seg = imm; offset = leb(c, false); break;
        case REBASE_OPCODE_ADD_ADDR_ULEB: if (!add(&offset, leb(c, false))) return false; break;
        case REBASE_OPCODE_ADD_ADDR_IMM_SCALED: if (!add(&offset, imm * 8)) return false; break;
        case REBASE_OPCODE_DO_REBASE_IMM_TIMES: count = imm; break;
        case REBASE_OPCODE_DO_REBASE_ULEB_TIMES: count = leb(c, false); break;
        case REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB: count = 1; skip = leb(c, false); break;
        case REBASE_OPCODE_DO_REBASE_ULEB_TIMES_SKIPPING_ULEB: count = leb(c, false); skip = leb(c, false); break;
        default: return false;
        }
        if (c->bad || skip > UINT64_MAX - 8) return false;
        if (count > limit - stats->rebases) {
            snprintf(error, error_size, "rebase count exceeds image pointer budget (%llu)", (unsigned long long)limit);
            return false;
        }
        while (count--) {
            uint64_t address, value;
            if (type != REBASE_TYPE_POINTER || !target(image, seg, offset, &address) ||
                gm_read(&image->memory, address, &value, 8) != GM_OK) return false;
            value += slide; // Mach-O pointer arithmetic intentionally wraps for negative slides.
            if (gm_populate(&image->memory, address, &value, 8) != GM_OK || !add(&offset, 8 + skip)) return false;
            stats->rebases++;
            notify(o, address, value, NULL);
        }
    }
    return false; // Missing DONE.
}
static bool binds(GuestImage *image, Cursor *c, bool lazy, bool weak_stream, GFResolve resolve,
                  void *context, const Observer *o, GFStats *stats, char *error, size_t error_size) {
    size_t seg = SIZE_MAX; uint64_t offset = 0, addend = 0;
    int ordinal = weak_stream ? BIND_SPECIAL_DYLIB_WEAK_LOOKUP : 0;
    unsigned type = BIND_TYPE_POINTER, flags = 0; const char *symbol = NULL;
    bool ended = false;
    while (c->p < c->end) {
        uint8_t byte = *c->p++, op = byte & 0xf0, imm = byte & 15;
        uint64_t count = 0, skip = 0;
        ended = false;
        switch (op) {
        case BIND_OPCODE_DONE:
            if (!lazy) return true;
            seg = SIZE_MAX; offset = addend = 0; ordinal = 0; flags = 0;
            type = BIND_TYPE_POINTER; symbol = NULL; ended = true; break;
        case BIND_OPCODE_SET_DYLIB_ORDINAL_IMM: ordinal = imm; break;
        case BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB: {
            uint64_t n = leb(c, false); if (n > image->dylib_count) return false; ordinal = (int)n; break;
        }
        case BIND_OPCODE_SET_DYLIB_SPECIAL_IMM: ordinal = imm ? (int)(int8_t)(imm | 0xf0) : 0; break;
        case BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM: {
            const uint8_t *end = memchr(c->p, 0, (size_t)(c->end - c->p));
            if (!end) return false;
            symbol = (const char *)c->p; c->p = end + 1; flags = imm; break;
        }
        case BIND_OPCODE_SET_TYPE_IMM: type = imm; break;
        case BIND_OPCODE_SET_ADDEND_SLEB: addend = leb(c, true); break;
        case BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB: seg = imm; offset = leb(c, false); break;
        // Apple linkers encode backward moves as wrapping unsigned ULEB deltas.
        // The resulting fixup target is bounds checked before any access.
        case BIND_OPCODE_ADD_ADDR_ULEB: offset += leb(c, false); break;
        case BIND_OPCODE_DO_BIND: count = 1; break;
        case BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB: count = 1; skip = leb(c, false); break;
        case BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED: count = 1; skip = imm * 8; break;
        case BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB: count = leb(c, false); skip = leb(c, false); break;
        default: return false;
        }
        if (c->bad || count > 1000000) return false;
        while (count--) {
            uint64_t address, value;
            if (type != BIND_TYPE_POINTER || !symbol || ordinal > (int)image->dylib_count || ordinal < -3 ||
                ++stats->binds > 1000000 || !target(image, seg, offset, &address)) {
                snprintf(error, error_size, "invalid bind target segment=%zu offset=%#llx type=%u ordinal=%d",
                         seg, (unsigned long long)offset, type, ordinal);
                return false;
            }
            if (!resolve(symbol, ordinal, (flags & BIND_SYMBOL_FLAGS_WEAK_IMPORT) || weak_stream, lazy, &value, context)) {
                snprintf(error, error_size, "unresolved import %s (ordinal %d)", symbol, ordinal); return false;
            }
            value += addend;
            if (gm_populate(&image->memory, address, &value, 8) != GM_OK) return false;
            notify(o, address, value, symbol);
            // Like ADD_ADDR_ULEB, bind-and-skip can encode a backward move as
            // an unsigned wrapping delta. Validate every resulting target above.
            offset += 8 + skip;
        }
    }
    return lazy && ended;
}
// Chained fixups: the pointers hold the records. Plain formats only.
typedef struct { const uint8_t *base; uint32_t size; } Blob;
typedef struct { const char *name; int ordinal; bool weak; uint64_t addend; } ChainedImport;

static const uint8_t *blob_at(const Blob *blob, uint64_t offset, uint64_t size) {
    if (offset > blob->size || size > blob->size - offset) return NULL;
    return blob->base + offset;
}
static bool blob_u16(const Blob *blob, uint64_t offset, uint16_t *out) {
    const uint8_t *at = blob_at(blob, offset, 2); if (at) memcpy(out, at, 2); return at;
}
static bool blob_u32(const Blob *blob, uint64_t offset, uint32_t *out) {
    const uint8_t *at = blob_at(blob, offset, 4); if (at) memcpy(out, at, 4); return at;
}
static bool blob_u64(const Blob *blob, uint64_t offset, uint64_t *out) {
    const uint8_t *at = blob_at(blob, offset, 8); if (at) memcpy(out, at, 8); return at;
}
static const char *blob_string(const Blob *blob, uint64_t offset) {
    if (offset >= blob->size) return NULL;
    const char *text = (const char *)blob->base + offset;
    return memchr(text, 0, blob->size - offset) ? text : NULL;
}
// Stored unsigned; as in dyld, the top sixteen values are special and
// sign-extend (-1 executable, -2 flat, -3 weak; the rest are refused).
static int chained_ordinal(uint64_t raw, uint64_t limit) {
    return raw > limit - 15 ? (int)((int64_t)raw - (int64_t)limit - 1) : (int)raw;
}

static bool chained(GuestImage *image, uint64_t slide, GFResolve resolve, void *context, const Observer *o,
                    GFStats *stats, char *error, size_t error_size) {
#define FAIL(...) do { if (error_size) snprintf(error, error_size, __VA_ARGS__); goto done; } while (0)
    bool ok = false;
    ChainedImport *imports = NULL;
    uint8_t *bytes = stream(image, image->chained_offset, image->chained_size);
    if (!bytes) { if (error_size) snprintf(error, error_size, "chained fixups outside readable image"); return false; }
    Blob blob = {bytes, image->chained_size};

    uint32_t version = 0, starts_offset = 0, imports_offset = 0, symbols_offset = 0;
    uint32_t imports_count = 0, imports_format = 0, symbols_format = 0;
    if (!blob_u32(&blob, 0, &version) || !blob_u32(&blob, 4, &starts_offset) ||
        !blob_u32(&blob, 8, &imports_offset) || !blob_u32(&blob, 12, &symbols_offset) ||
        !blob_u32(&blob, 16, &imports_count) || !blob_u32(&blob, 20, &imports_format) ||
        !blob_u32(&blob, 24, &symbols_format)) FAIL("truncated chained fixups header");
    if (version != 0) FAIL("unsupported chained fixups version %u", version);
    if (symbols_format) FAIL("compressed chained symbol names are unsupported");

    size_t entry = imports_format == DYLD_CHAINED_IMPORT ? 4 :
                   imports_format == DYLD_CHAINED_IMPORT_ADDEND ? 8 :
                   imports_format == DYLD_CHAINED_IMPORT_ADDEND64 ? 16 : 0;
    if (!entry) FAIL("unsupported chained imports format %u", imports_format);
    if (imports_count > blob.size / entry) FAIL("chained imports outside the fixups blob");
    imports = calloc(imports_count ? imports_count : 1, sizeof *imports);
    if (!imports) FAIL("cannot hold the chained import table");
    for (uint32_t i = 0; i < imports_count; i++) {
        uint64_t at = (uint64_t)imports_offset + (uint64_t)i * entry, name_offset = 0;
        if (imports_format == DYLD_CHAINED_IMPORT_ADDEND64) {
            uint64_t raw = 0;
            if (!blob_u64(&blob, at, &raw) || !blob_u64(&blob, at + 8, &imports[i].addend))
                FAIL("chained import %u outside the fixups blob", i);
            imports[i].ordinal = chained_ordinal(raw & 0xFFFF, 0xFFFF);
            imports[i].weak = (raw >> 16) & 1;
            name_offset = raw >> 32;
        } else {
            uint32_t raw = 0;
            if (!blob_u32(&blob, at, &raw)) FAIL("chained import %u outside the fixups blob", i);
            imports[i].ordinal = chained_ordinal(raw & 0xFF, 0xFF);
            imports[i].weak = (raw >> 8) & 1;
            name_offset = raw >> 9;
            uint32_t addend = 0;
            if (entry == 8) {
                if (!blob_u32(&blob, at + 4, &addend)) FAIL("chained import %u addend missing", i);
                imports[i].addend = (uint64_t)(int64_t)(int32_t)addend;
            }
        }
        imports[i].name = blob_string(&blob, (uint64_t)symbols_offset + name_offset);
        if (!imports[i].name) FAIL("chained import %u names nothing inside the blob", i);
        // The same range the opcode binds accept.
        if (imports[i].ordinal < BIND_SPECIAL_DYLIB_WEAK_LOOKUP || imports[i].ordinal > (int)image->dylib_count)
            FAIL("invalid chained import ordinal %d", imports[i].ordinal);
    }

    uint32_t segment_count = 0;
    if (!blob_u32(&blob, starts_offset, &segment_count)) FAIL("chained starts outside the fixups blob");
    uint64_t steps_allowed = image->mapped_size / 4 + 1;
    for (uint32_t i = 0; i < segment_count; i++) {
        uint32_t info = 0;
        if (!blob_u32(&blob, (uint64_t)starts_offset + 4 + (uint64_t)i * 4, &info))
            FAIL("chained starts for segment %u outside the blob", i);
        if (!info) continue;
        // Starts are listed per segment, in load command order.
        if (i >= image->segment_count) FAIL("chained starts for segment %u of %zu", i, image->segment_count);
        const GISegment *segment = &image->segments[i];
        uint64_t at = (uint64_t)starts_offset + info;
        uint16_t page_size = 0, format = 0, page_count = 0;
        uint64_t segment_offset = 0;
        if (!blob_u16(&blob, at + 4, &page_size) || !blob_u16(&blob, at + 6, &format) ||
            !blob_u64(&blob, at + 8, &segment_offset) || !blob_u16(&blob, at + 20, &page_count))
            FAIL("chained starts for segment %u are truncated", i);
        if (format != DYLD_CHAINED_PTR_64 && format != DYLD_CHAINED_PTR_64_OFFSET)
            FAIL("unsupported chained pointer format %u", format);
        if (page_size != 4096 && page_size != 16384) FAIL("unsupported chained page size %u", page_size);
        for (uint16_t page = 0; page < page_count; page++) {
            uint16_t start = 0;
            if (!blob_u16(&blob, at + 22 + (uint64_t)page * 2, &start))
                FAIL("chained page table for segment %u is truncated", i);
            if (start == DYLD_CHAINED_PTR_START_NONE) continue;
            // Several chains on a page list their starts further along.
            uint64_t list = start & DYLD_CHAINED_PTR_START_MULTI ?
                at + 22 + (uint64_t)(start & ~DYLD_CHAINED_PTR_START_MULTI) * 2 : 0;
            for (unsigned chain = 0;; chain++) {
                uint16_t offset = start;
                if (list) {
                    if (!blob_u16(&blob, list + (uint64_t)chain * 2, &offset))
                        FAIL("chained start list for segment %u is truncated", i);
                }
                if ((offset & ~DYLD_CHAINED_PTR_START_LAST) >= page_size)
                    FAIL("chained start beyond its own page");
                // A chain stays on its own page, inside its own segment.
                uint64_t page_start = image->header_address + segment_offset + (uint64_t)page * page_size;
                uint64_t page_end = page_start + page_size;
                if (page_start < segment->address || page_start >= segment->address + segment->size)
                    FAIL("chained page %u outside segment %s", page, segment->name);
                if (page_end > segment->address + segment->size) page_end = segment->address + segment->size;
                uint64_t address = page_start + (offset & ~DYLD_CHAINED_PTR_START_LAST);
                for (uint64_t step = 0;; step++) {
                    if (step > steps_allowed) FAIL("chained pointers do not end");
                    if (address > page_end - 8 || address < page_start) FAIL("chained pointer leaves its page");
                    uint64_t raw = 0, value = 0;
                    if (gm_read(&image->memory, address, &raw, 8) != GM_OK)
                        FAIL("chained pointer outside guest memory");
                    // Linkers leave the reserved bits zero; anything else is corrupt.
                    if (raw >> 63) {
                        uint32_t ordinal = raw & 0xFFFFFF;
                        if ((raw >> 32) & 0x7FFFF) FAIL("chained bind at %#llx sets reserved bits", (unsigned long long)address);
                        if (ordinal >= imports_count) FAIL("chained bind names import %u of %u", ordinal, imports_count);
                        const ChainedImport *import = &imports[ordinal];
                        if (!resolve(import->name, import->ordinal, import->weak, false, &value, context) && !import->weak)
                            FAIL("unresolved import %s (ordinal %d)", import->name, import->ordinal);
                        value += import->addend + ((raw >> 24) & 0xFF);
                        stats->binds++;
                    } else {
                        if ((raw >> 44) & 0x7F) FAIL("chained rebase at %#llx sets reserved bits", (unsigned long long)address);
                        value = (raw & 0xFFFFFFFFFULL) | (((raw >> 36) & 0xFF) << 56);
                        if (format == DYLD_CHAINED_PTR_64_OFFSET) value += image->header_address;
                        value += slide;
                        stats->rebases++;
                    }
                    if (gm_populate(&image->memory, address, &value, 8) != GM_OK)
                        FAIL("cannot write a chained pointer");
                    notify(o, address, value, raw >> 63 ? imports[raw & 0xFFFFFF].name : NULL);
                    uint32_t next = (raw >> 51) & 0xFFF;
                    if (!next) break;
                    address += (uint64_t)next * 4;
                }
                if (!list || (offset & DYLD_CHAINED_PTR_START_LAST)) break;
            }
        }
    }
    ok = true;
done:
    free(imports); free(bytes);
    return ok;
#undef FAIL
}

bool gf_apply(GuestImage *image, uint64_t slide, GFResolve resolve, void *context,
              GFStats *stats, char *error, size_t error_size) {
    return gf_apply_observed(image, slide, resolve, context, NULL, NULL, stats, error, error_size);
}
bool gf_apply_observed(GuestImage *image, uint64_t slide, GFResolve resolve, void *context,
                       GFObserve observe, void *observe_context, GFStats *stats, char *error, size_t error_size) {
    *stats = (GFStats){0};
    if (error_size) error[0] = 0;
    if (!resolve) { snprintf(error, error_size, "unsupported fixup configuration"); return false; }
    Observer o = {observe, observe_context};
    if (image->chained_fixups) {
        // Linkers emit one or the other; both is a malformed image.
        if (image->rebase_size || image->bind_size || image->lazy_bind_size || image->weak_bind_size) {
            snprintf(error, error_size, "chained fixups together with dyld info opcodes"); return false;
        }
        return chained(image, slide, resolve, context, &o, stats, error, error_size);
    }
    // Lazy first: a name bound both ways is a call.
    const uint32_t offsets[] = {image->rebase_offset, image->lazy_bind_offset, image->bind_offset, image->weak_bind_offset};
    const uint32_t sizes[] = {image->rebase_size, image->lazy_bind_size, image->bind_size, image->weak_bind_size};
    for (size_t i = 0; i < 4; i++) {
        if (!sizes[i]) continue;
        uint8_t *bytes = stream(image, offsets[i], sizes[i]);
        if (!bytes) { snprintf(error, error_size, "fixup stream outside readable image"); return false; }
        Cursor c = {bytes, bytes + sizes[i], false};
        bool ok = i == 0 ? rebases(image, &c, slide, &o, stats, error, error_size) : binds(image, &c, i == 1, i == 3, resolve, context, &o, stats, error, error_size);
        size_t consumed = (size_t)(c.p - bytes);
        free(bytes);
        if (!ok) { if (error_size && !error[0]) snprintf(error, error_size, "invalid or unsupported fixup stream %zu at byte %zu (rebases=%zu binds=%zu)", i, consumed, stats->rebases, stats->binds); return false; }
    }
    return true;
}
