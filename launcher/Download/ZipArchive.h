#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// A reader for plain ZIP archives that came from the network: stored and
// deflated entries only. Every offset and length is checked against the file
// and anything that does not fit fails. ZIP64, encryption, archives in
// several parts and other compression methods are refused. The archive is
// read from its file piece by piece, never as a whole, so one of a gigabyte
// or two costs no more memory than a small one.

enum { ZA_MAX_ENTRIES = 100000, ZA_MAX_NAME = 512 };

typedef struct {
    const char *name;         // inside the archive's directory, not NUL-terminated
    uint16_t name_length;
    uint16_t method;          // 0 stored, 8 deflated
    uint32_t crc, stored, size, offset;
    uint32_t mode;            // Unix st_mode when the archive was made on Unix, else 0
} ZAEntry;

typedef struct {
    int fd;
    uint64_t size, directory_offset;
    uint8_t *directory;       // the central directory, owned
    uint32_t count;
    ZAEntry *entries;
} ZAArchive;

bool za_open(ZAArchive *archive, const char *path);
void za_close(ZAArchive *archive);

// Hands entry `index`'s content to `sink` in order. False for a malformed
// entry, content whose length or CRC-32 differs from the directory's, or
// when the sink returns false; the sink never receives more than the
// entry's stated size.
typedef bool (*ZASink)(void *context, const uint8_t *bytes, size_t length);
bool za_extract(const ZAArchive *archive, uint32_t index, ZASink sink, void *context);
