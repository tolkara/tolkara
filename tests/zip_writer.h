#pragma once
// A tiny ZIP writer for the tests' made-up archives: stored and deflated
// entries, optional Unix modes, no ZIP64.
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

typedef struct { uint8_t *bytes; size_t size, capacity; } ZWBuffer;
typedef struct { ZWBuffer file, directory; unsigned count; size_t directory_offset; } ZipWriter;

static void zw_bytes(ZWBuffer *buffer, const void *bytes, size_t length) {
    if (buffer->size + length > buffer->capacity) {
        buffer->capacity = (buffer->size + length) * 2 + 64;
        buffer->bytes = realloc(buffer->bytes, buffer->capacity);
        assert(buffer->bytes);
    }
    if (length) memcpy(buffer->bytes + buffer->size, bytes, length);
    buffer->size += length;
}
static void zw_16(ZWBuffer *buffer, unsigned value) { uint8_t b[2] = {(uint8_t)value, (uint8_t)(value >> 8)}; zw_bytes(buffer, b, 2); }
static void zw_32(ZWBuffer *buffer, uint32_t value) { zw_16(buffer, value & 0xFFFF); zw_16(buffer, value >> 16); }

// mode: a Unix st_mode (the archive then says it was made on Unix), or 0.
static void zw_add(ZipWriter *writer, const char *name, const void *data, size_t size, int deflated, uint32_t mode) {
    uint8_t *packed = NULL;
    size_t stored = size;
    if (deflated) {
        z_stream stream = {0};
        assert(deflateInit2(&stream, 6, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) == Z_OK);
        uLong bound = deflateBound(&stream, (uLong)size);
        packed = malloc(bound ? bound : 1);
        stream.next_in = (Bytef *)data; stream.avail_in = (uInt)size;
        stream.next_out = packed; stream.avail_out = (uInt)bound;
        assert(deflate(&stream, Z_FINISH) == Z_STREAM_END);
        stored = stream.total_out;
        deflateEnd(&stream);
    }
    uint32_t crc = (uint32_t)crc32(crc32(0, NULL, 0), data, (uInt)size), offset = (uint32_t)writer->file.size;
    size_t length = strlen(name);
    ZWBuffer *file = &writer->file, *directory = &writer->directory;
    zw_32(file, 0x04034b50); zw_16(file, 20); zw_16(file, 0); zw_16(file, deflated ? 8 : 0); zw_32(file, 0);
    zw_32(file, crc); zw_32(file, (uint32_t)stored); zw_32(file, (uint32_t)size); zw_16(file, (unsigned)length); zw_16(file, 0);
    zw_bytes(file, name, length);
    zw_bytes(file, deflated ? packed : data, stored);
    zw_32(directory, 0x02014b50); zw_16(directory, mode ? 3 << 8 | 20 : 20); zw_16(directory, 20); zw_16(directory, 0);
    zw_16(directory, deflated ? 8 : 0); zw_32(directory, 0);
    zw_32(directory, crc); zw_32(directory, (uint32_t)stored); zw_32(directory, (uint32_t)size);
    zw_16(directory, (unsigned)length); zw_16(directory, 0); zw_16(directory, 0); zw_16(directory, 0); zw_16(directory, 0);
    zw_32(directory, mode << 16); zw_32(directory, offset);
    zw_bytes(directory, name, length);
    writer->count++;
    free(packed);
}
// The directory and the end record; writer->file is then the archive.
static void zw_finish(ZipWriter *writer) {
    ZWBuffer *file = &writer->file;
    writer->directory_offset = file->size;
    zw_bytes(file, writer->directory.bytes, writer->directory.size);
    zw_32(file, 0x06054b50); zw_16(file, 0); zw_16(file, 0); zw_16(file, writer->count); zw_16(file, writer->count);
    zw_32(file, (uint32_t)writer->directory.size); zw_32(file, (uint32_t)writer->directory_offset); zw_16(file, 0);
}
static void zw_free(ZipWriter *writer) { free(writer->file.bytes); free(writer->directory.bytes); memset(writer, 0, sizeof *writer); }
