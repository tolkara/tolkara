#include "ZipArchive.h"
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }

enum { END_SIZE = 22, DIRECTORY_ENTRY = 46, LOCAL_HEADER = 30, LOCATOR_SIZE = 20, PIECE = 1 << 16,
       MAX_DIRECTORY = 64 << 20 };

// All of `length` bytes at `offset`, or false.
static bool read_at(int fd, uint64_t offset, uint8_t *out, size_t length) {
    while (length) {
        ssize_t got = pread(fd, out, length, (off_t)offset);
        if (got <= 0) return false;
        out += got; offset += (uint64_t)got; length -= (size_t)got;
    }
    return true;
}

void za_close(ZAArchive *archive) {
    if (archive->fd >= 0) close(archive->fd);
    free(archive->directory); free(archive->entries);
    memset(archive, 0, sizeof *archive);
    archive->fd = -1;
}

bool za_open(ZAArchive *archive, const char *path) {
    memset(archive, 0, sizeof *archive);
    archive->fd = open(path, O_RDONLY | O_CLOEXEC);
    struct stat status;
    if (archive->fd < 0 || fstat(archive->fd, &status) || !S_ISREG(status.st_mode) || status.st_size < END_SIZE) { za_close(archive); return false; }
    archive->size = (uint64_t)status.st_size;

    // The end record: the last thing in the file, after it only its own comment.
    size_t tail_size = archive->size < END_SIZE + 65535 ? (size_t)archive->size : END_SIZE + 65535;
    uint8_t *tail = malloc(tail_size);
    if (!tail || !read_at(archive->fd, archive->size - tail_size, tail, tail_size)) { free(tail); za_close(archive); return false; }
    size_t end = SIZE_MAX;
    for (size_t at = tail_size - END_SIZE + 1; at-- > 0;)
        if (le32(tail + at) == 0x06054b50 && at + END_SIZE + le16(tail + at + 20) == tail_size) { end = at; break; }
    if (end == SIZE_MAX) { free(tail); za_close(archive); return false; }
    const uint8_t *record = tail + end;
    uint64_t end_offset = archive->size - tail_size + end;
    uint16_t disk = le16(record + 4), directory_disk = le16(record + 6), here = le16(record + 8), total = le16(record + 10);
    uint32_t directory_size = le32(record + 12), directory_offset = le32(record + 16);
    // ZIP64: its locator before the end record, or the values that point to it.
    bool zip64 = total == 0xFFFF || here == 0xFFFF || directory_size == 0xFFFFFFFF || directory_offset == 0xFFFFFFFF ||
        (end >= LOCATOR_SIZE && le32(record - LOCATOR_SIZE) == 0x07064b50);
    if (!zip64 && end < LOCATOR_SIZE && end_offset >= LOCATOR_SIZE) {
        uint8_t locator[4];
        zip64 = !read_at(archive->fd, end_offset - LOCATOR_SIZE, locator, 4) || le32(locator) == 0x07064b50;
    }
    free(tail);
    if (zip64 || disk || directory_disk || here != total || (uint32_t)total > ZA_MAX_ENTRIES || directory_size > MAX_DIRECTORY ||
        (uint64_t)directory_offset + directory_size != end_offset || (uint64_t)total * DIRECTORY_ENTRY > directory_size) { za_close(archive); return false; }
    archive->directory_offset = directory_offset;
    archive->count = total;
    archive->directory = malloc(directory_size ? directory_size : 1);
    archive->entries = calloc(total ? total : 1, sizeof(ZAEntry));
    if (!archive->directory || !archive->entries || !read_at(archive->fd, directory_offset, archive->directory, directory_size)) { za_close(archive); return false; }

    size_t at = 0;
    for (uint32_t i = 0; i < total; i++) {
        const uint8_t *p = archive->directory + at;
        if (directory_size - at < DIRECTORY_ENTRY || le32(p) != 0x02014b50) { za_close(archive); return false; }
        uint16_t made_by = le16(p + 4), flags = le16(p + 8), name_length = le16(p + 28), extra = le16(p + 30), comment = le16(p + 32);
        ZAEntry *entry = &archive->entries[i];
        entry->method = le16(p + 10);
        entry->crc = le32(p + 16); entry->stored = le32(p + 20); entry->size = le32(p + 24);
        entry->offset = le32(p + 42);
        entry->name = (const char *)p + DIRECTORY_ENTRY; entry->name_length = name_length;
        entry->mode = made_by >> 8 == 3 ? le32(p + 38) >> 16 : 0;
        size_t length = (size_t)DIRECTORY_ENTRY + name_length + extra + comment;
        // Encrypted (bit 0, bit 6), patched data (bit 5) and a masked directory (bit 13) are refused.
        if (length > directory_size - at || (flags & 0x2061) || le16(p + 34) || !name_length || name_length > ZA_MAX_NAME ||
            memchr(entry->name, 0, name_length) || (entry->method != 0 && entry->method != 8) ||
            entry->stored == 0xFFFFFFFF || entry->size == 0xFFFFFFFF || entry->offset == 0xFFFFFFFF ||
            (entry->method == 0 && entry->stored != entry->size) ||
            // The local header and the content lie before the directory.
            (uint64_t)entry->offset + LOCAL_HEADER + name_length + entry->stored > directory_offset) { za_close(archive); return false; }
        at += length;
    }
    if (at != directory_size) { za_close(archive); return false; }
    return true;
}

bool za_extract(const ZAArchive *archive, uint32_t index, ZASink sink, void *context) {
    if (!archive || archive->fd < 0 || index >= archive->count || !sink) return false;
    const ZAEntry *entry = &archive->entries[index];
    uint8_t header[LOCAL_HEADER];
    if (!read_at(archive->fd, entry->offset, header, sizeof header) || le32(header) != 0x04034b50 || (le16(header + 6) & 1) ||
        le16(header + 8) != entry->method) return false;
    uint64_t data = (uint64_t)entry->offset + LOCAL_HEADER + le16(header + 26) + le16(header + 28);
    if (data + entry->stored > archive->directory_offset) return false;

    uint8_t *in = malloc(PIECE), *out = entry->method == 8 ? malloc(PIECE) : NULL;
    bool ok = in && (entry->method != 8 || out);
    uint32_t crc = (uint32_t)crc32(0, NULL, 0), left = entry->stored;
    uint64_t made = 0;
    if (ok && entry->method == 0) {
        while (ok && left) {
            uint32_t piece = left < PIECE ? left : PIECE;
            ok = read_at(archive->fd, data, in, piece);
            if (ok) { crc = (uint32_t)crc32(crc, in, piece); ok = sink(context, in, piece); }
            data += piece; left -= piece; made += piece;
        }
    } else if (ok) {
        z_stream stream = {0};
        bool started = inflateInit2(&stream, -MAX_WBITS) == Z_OK;
        int status = Z_OK;
        ok = started;
        while (ok && status != Z_STREAM_END) {
            if (!stream.avail_in) {
                uint32_t piece = left < PIECE ? left : PIECE;
                if (!piece || !read_at(archive->fd, data, in, piece)) { ok = false; break; }   // the stream wants more than the entry has
                data += piece; left -= piece;
                stream.next_in = in; stream.avail_in = piece;
            }
            stream.next_out = out; stream.avail_out = PIECE;
            status = inflate(&stream, Z_NO_FLUSH);
            size_t got = PIECE - stream.avail_out;
            if (status != Z_OK && status != Z_STREAM_END) ok = false;
            else if (made + got > entry->size) ok = false;   // more than the directory says: not handed on
            else if (got) { crc = (uint32_t)crc32(crc, out, (uInt)got); made += got; ok = sink(context, out, got); }
        }
        // The stream ends where the entry does.
        if (ok && (left || stream.avail_in)) ok = false;
        if (started) inflateEnd(&stream);
    }
    free(in); free(out);
    return ok && made == entry->size && crc == entry->crc;
}
