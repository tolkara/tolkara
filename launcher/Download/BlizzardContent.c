#include "BlizzardContent.h"
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint16_t be16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }

#pragma mark BLTE

static bool blte_chunk(const uint8_t *chunk, size_t size, BCSink sink, void *context) {
    if (!size) return false;
    if (chunk[0] == 'N') return size == 1 || sink(context, chunk + 1, size - 1);
    if (chunk[0] != 'Z') return false;   // 'E' (encrypted) and others: not supported
    z_stream stream = {0};
    if (inflateInit(&stream) != Z_OK) return false;
    stream.next_in = (Bytef *)(chunk + 1);
    stream.avail_in = (uInt)(size - 1);
    uint8_t *out = malloc(1 << 16);
    bool ok = out != NULL;
    int status = Z_OK;
    while (ok && status != Z_STREAM_END) {
        stream.next_out = out; stream.avail_out = 1 << 16;
        status = inflate(&stream, Z_NO_FLUSH);
        size_t made = (1 << 16) - stream.avail_out;
        if (status != Z_OK && status != Z_STREAM_END) ok = false;
        else if (made && !sink(context, out, made)) ok = false;
        else if (status == Z_OK && !made && !stream.avail_in) ok = false;   // truncated
    }
    free(out);
    inflateEnd(&stream);
    return ok;
}

bool bc_blte_decode(const uint8_t *data, size_t size, BCSink sink, void *context) {
    if (!data || !sink || size < 8 || memcmp(data, "BLTE", 4)) return false;
    uint32_t header = be32(data + 4);
    if (!header) return blte_chunk(data + 8, size - 8, sink, context);
    if (header < 12 || header > size || size - 8 > UINT32_MAX) return false;
    uint32_t count = be32(data + 8) & 0xFFFFFF;
    if (!count || (uint64_t)12 + (uint64_t)count * 24 > header) return false;
    size_t offset = header;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t stored = be32(data + 12 + (size_t)i * 24);
        if (stored > size - offset) return false;
        if (!blte_chunk(data + offset, stored, sink, context)) return false;
        offset += stored;
    }
    return true;
}

#pragma mark Install manifest

// The end of a NUL-terminated string starting at `from`, or 0.
static size_t string_end(const uint8_t *data, size_t size, size_t from) {
    if (from >= size) return 0;
    const uint8_t *end = memchr(data + from, 0, size - from);
    return end ? (size_t)(end - data) : 0;
}

bool bc_install_open(BCInstall *install, const uint8_t *data, size_t size) {
    memset(install, 0, sizeof *install);
    if (!data || size < 10 || data[0] != 'I' || data[1] != 'N') return false;
    install->data = data; install->size = size;
    install->hash_size = data[3];
    install->tag_count = be16(data + 4);
    install->entry_count = be32(data + 6);
    if (install->hash_size != 16 || install->entry_count > 1u << 20) return false;
    install->mask = (install->entry_count + 7) / 8;
    install->tags = calloc(install->tag_count ? install->tag_count : 1, sizeof(size_t));
    install->entries = calloc(install->entry_count ? install->entry_count : 1, sizeof(size_t));
    if (!install->tags || !install->entries) { bc_install_close(install); return false; }
    size_t position = 10;
    for (uint16_t i = 0; i < install->tag_count; i++) {
        size_t end = string_end(data, size, position);
        // name, NUL, a 16-bit type, the bitmap
        if (!end || end == position || size - end < 3 + install->mask) { bc_install_close(install); return false; }
        install->tags[i] = position;
        position = end + 3 + install->mask;
    }
    for (uint32_t i = 0; i < install->entry_count; i++) {
        size_t end = string_end(data, size, position);
        // name, NUL, the content key, a 32-bit size
        if (!end || end == position || size - end < 1 + 16 + 4) { bc_install_close(install); return false; }
        install->entries[i] = position;
        position = end + 1 + 16 + 4;
    }
    return true;
}

void bc_install_close(BCInstall *install) {
    free(install->tags); free(install->entries);
    memset(install, 0, sizeof *install);
}

int bc_install_tag(const BCInstall *install, const char *name) {
    for (uint16_t i = 0; i < install->tag_count; i++)
        if (!strcmp((const char *)install->data + install->tags[i], name)) return i;
    return -1;
}

bool bc_install_has_tag(const BCInstall *install, uint32_t entry, int tag) {
    if (tag < 0 || tag >= install->tag_count || entry >= install->entry_count) return false;
    const char *name = (const char *)install->data + install->tags[tag];
    const uint8_t *bits = (const uint8_t *)name + strlen(name) + 3;
    return (bits[entry / 8] & (0x80 >> (entry % 8))) != 0;
}

const char *bc_install_entry(const BCInstall *install, uint32_t entry, const uint8_t **ckey, uint32_t *size) {
    if (entry >= install->entry_count) return NULL;
    const char *name = (const char *)install->data + install->entries[entry];
    const uint8_t *after = (const uint8_t *)name + strlen(name) + 1;
    if (ckey) *ckey = after;
    if (size) *size = be32(after + 16);
    return name;
}

#pragma mark Encoding table

bool bc_encoding_lookup(const uint8_t *data, size_t size, const uint8_t *ckeys, size_t count, uint8_t *ekeys, bool *found) {
    for (size_t i = 0; i < count; i++) found[i] = false;
    if (!data || size < 22 || data[0] != 'E' || data[1] != 'N') return false;
    uint8_t ckey_size = data[3], ekey_size = data[4];
    size_t page = (size_t)be16(data + 5) * 1024;
    uint32_t pages = be32(data + 9), espec = be32(data + 18);
    if (ckey_size != 16 || ekey_size != 16 || !page || !pages) return false;
    // header, the encoding specifications, the page table (first key and a
    // checksum for each page), then the pages
    uint64_t table = (uint64_t)22 + espec, first = table + (uint64_t)pages * 32;
    if (first + (uint64_t)pages * page > size) return false;
    for (size_t i = 0; i < count; i++) {
        const uint8_t *wanted = ckeys + i * 16;
        // The last page whose first key is not after the wanted one.
        uint32_t low = 0, high = pages;
        while (high - low > 1) {
            uint32_t middle = low + (high - low) / 2;
            if (memcmp(data + table + (uint64_t)middle * 32, wanted, 16) <= 0) low = middle; else high = middle;
        }
        const uint8_t *block = data + first + (uint64_t)low * page;
        size_t position = 0;
        // key count, a 40-bit size, the content key, then that many encoded keys
        while (position + 6 + 16 <= page && block[position]) {
            size_t length = 6 + 16 + (size_t)block[position] * 16;
            if (position + length > page) return false;
            if (!memcmp(block + position + 6, wanted, 16)) {
                memcpy(ekeys + i * 16, block + position + 6 + 16, 16);
                found[i] = true;
                break;
            }
            position += length;
        }
    }
    return true;
}

#pragma mark Archive index

bool bc_index_scan(const uint8_t *data, size_t size, BCIndexVisit visit, void *context) {
    // Footer: a table checksum (8), version, two unused bytes, the block size
    // in KB, the widths of the offset, size and key fields, the checksum
    // width, the entry count (little-endian) and the footer's checksum (8).
    if (!data || size < 28) return false;
    const uint8_t *footer = data + size - 28;
    size_t block = (size_t)footer[11] * 1024;
    uint8_t offset_bytes = footer[12], size_bytes = footer[13], key_size = footer[14], checksum = footer[15];
    uint32_t count = (uint32_t)footer[16] | (uint32_t)footer[17] << 8 | (uint32_t)footer[18] << 16 | (uint32_t)footer[19] << 24;
    if (!block || offset_bytes != 4 || size_bytes != 4 || key_size != 16 || checksum != 8) return false;
    const size_t entry = 16 + 4 + 4;
    uint32_t seen = 0;
    for (size_t position = 0; seen < count; position += block) {
        if (position + block > size - 28) return false;
        for (size_t i = 0; i + entry <= block && seen < count; i += entry) {
            const uint8_t *item = data + position + i;
            static const uint8_t none[16];
            if (!memcmp(item, none, 16)) break;   // the rest of the block is padding
            visit(context, item, be32(item + 16), be32(item + 20));
            seen++;
        }
    }
    return true;
}
