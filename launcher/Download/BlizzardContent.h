#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Readers for the files Blizzard's content servers hand out (the formats its
// own launcher downloads a game with). Everything here is data from the
// network: each reader checks every offset and length and fails on anything
// that does not fit. Nothing here knows a game, and nothing is executed.

// BLTE: a container of chunks, each stored plainly or zlib-compressed.
// Decodes `data`, handing each piece of decoded content to `sink` in order.
// False for a malformed container, an unsupported chunk (an encrypted one) or
// when the sink returns false.
typedef bool (*BCSink)(void *context, const uint8_t *bytes, size_t length);
bool bc_blte_decode(const uint8_t *data, size_t size, BCSink sink, void *context);

// Install manifest: the files a product installs outside its data archives
// (its application), each with a content key, a size and tags (system, CPU,
// region, language).
typedef struct {
    const uint8_t *data;
    size_t size, mask;        // mask: bytes of one tag's bitmap
    uint8_t hash_size;
    uint16_t tag_count;
    uint32_t entry_count;
    size_t *tags, *entries;   // offsets of each tag and entry in data
} BCInstall;
bool bc_install_open(BCInstall *install, const uint8_t *data, size_t size);
void bc_install_close(BCInstall *install);
// A tag's number by name, or -1.
int bc_install_tag(const BCInstall *install, const char *name);
bool bc_install_has_tag(const BCInstall *install, uint32_t entry, int tag);
// An entry's name (inside data, NUL-terminated), content key and size.
const char *bc_install_entry(const BCInstall *install, uint32_t entry, const uint8_t **ckey, uint32_t *size);

// Encoding table: content key -> encoded key (the name a file is stored
// under). Looks up `count` 16-byte content keys; ekeys receives 16 bytes for
// each one found. False for a malformed table.
bool bc_encoding_lookup(const uint8_t *data, size_t size, const uint8_t *ckeys, size_t count, uint8_t *ekeys, bool *found);

// Archive index: encoded key -> where the file lies inside one archive.
typedef void (*BCIndexVisit)(void *context, const uint8_t *ekey, uint32_t size, uint32_t offset);
bool bc_index_scan(const uint8_t *data, size_t size, BCIndexVisit visit, void *context);
