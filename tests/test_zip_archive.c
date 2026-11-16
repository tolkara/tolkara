// The ZIP reader on archives made up here, intact and damaged in every way
// it has to refuse.
#include "ZipArchive.h"
#include "zip_writer.h"
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

static char path[1024];

typedef struct { uint8_t *bytes; size_t size, limit; } Collected;
static bool collect(void *context, const uint8_t *bytes, size_t length) {
    Collected *out = context;
    assert(out->size + length <= out->limit);   // never more than the entry's stated size
    memcpy(out->bytes + out->size, bytes, length);
    out->size += length;
    return true;
}
static bool refuse(void *context, const uint8_t *bytes, size_t length) { (void)context; (void)bytes; (void)length; return false; }

static void put(const uint8_t *bytes, size_t size) {
    FILE *file = fopen(path, "wb");
    assert(file && fwrite(bytes, 1, size, file) == size && !fclose(file));
}
static bool opens(const uint8_t *bytes, size_t size) {
    put(bytes, size);
    ZAArchive archive;
    bool ok = za_open(&archive, path);
    if (ok) za_close(&archive); else assert(archive.fd == -1 && !archive.entries && !archive.directory);
    return ok;
}
// -1: does not open; 0: the entry is refused; 1: extracted.
static int extracts(const uint8_t *bytes, size_t size, uint32_t index) {
    put(bytes, size);
    ZAArchive archive;
    if (!za_open(&archive, path)) return -1;
    Collected out = {malloc(archive.entries[index].size + 1), 0, archive.entries[index].size};
    int ok = za_extract(&archive, index, collect, &out);
    free(out.bytes);
    za_close(&archive);
    return ok;
}
static uint8_t *copy(const ZipWriter *writer) {
    uint8_t *bytes = malloc(writer->file.size);
    memcpy(bytes, writer->file.bytes, writer->file.size);
    return bytes;
}
static void set16(uint8_t *p, unsigned value) { p[0] = (uint8_t)value; p[1] = (uint8_t)(value >> 8); }
static void set32(uint8_t *p, uint32_t value) { set16(p, value & 0xFFFF); set16(p + 2, value >> 16); }

int main(void) {
    const char *temporary = getenv("TMPDIR");
    snprintf(path, sizeof path, "%s/tolkara-zip-test-%d.zip", temporary && *temporary ? temporary : "/tmp", (int)getpid());

    static uint8_t big[300000];
    for (size_t i = 0; i < sizeof big; i++) big[i] = (uint8_t)(i % 251 + (i >> 9));
    const char *hello = "hello zip\n";
    ZipWriter writer = {0};
    zw_add(&writer, "a.txt", hello, strlen(hello), 0, 0);
    zw_add(&writer, "dir/big.bin", big, sizeof big, 1, S_IFREG | 0755);
    zw_add(&writer, "empty", "", 0, 0, S_IFREG | 0644);
    zw_add(&writer, "dir/", "", 0, 0, S_IFDIR | 0755);
    zw_add(&writer, "packed-empty", "", 0, 1, 0);
    zw_finish(&writer);
    size_t size = writer.file.size, directory = writer.directory_offset, end = size - 22;
    size_t second = directory + 46 + 5;   // the second entry's directory record

    // An intact archive: names, sizes, modes and content.
    put(writer.file.bytes, size);
    ZAArchive archive;
    assert(za_open(&archive, path) && archive.count == 5);
    assert(archive.entries[0].name_length == 5 && !memcmp(archive.entries[0].name, "a.txt", 5) && archive.entries[0].method == 0 && !archive.entries[0].mode);
    assert(archive.entries[1].name_length == 11 && !memcmp(archive.entries[1].name, "dir/big.bin", 11) && archive.entries[1].method == 8);
    assert(archive.entries[1].size == sizeof big && archive.entries[1].stored < sizeof big && archive.entries[1].mode == (S_IFREG | 0755));
    assert(archive.entries[3].mode == (S_IFDIR | 0755));
    Collected out = {malloc(sizeof big), 0, sizeof big};
    assert(za_extract(&archive, 1, collect, &out) && out.size == sizeof big && !memcmp(out.bytes, big, sizeof big));
    out.size = 0; out.limit = strlen(hello);
    assert(za_extract(&archive, 0, collect, &out) && out.size == strlen(hello) && !memcmp(out.bytes, hello, out.size));
    out.size = 0; out.limit = 0;
    assert(za_extract(&archive, 2, collect, &out) && za_extract(&archive, 4, collect, &out) && !out.size);
    assert(!za_extract(&archive, 5, collect, &out) && !za_extract(&archive, 1, refuse, NULL) && !za_extract(&archive, 0, refuse, NULL));
    za_close(&archive);
    za_close(&archive);   // harmless twice
    free(out.bytes);
    assert(!za_open(&archive, "/nonexistent/archive.zip") && !za_open(&archive, temporary && *temporary ? temporary : "/tmp"));

    // A comment after the end record is fine; anything else after it is not.
    uint8_t *bytes = malloc(size + 7);
    memcpy(bytes, writer.file.bytes, size); memcpy(bytes + size, "comment", 7);
    assert(!opens(bytes, size + 7));
    set16(bytes + end + 20, 7);
    assert(extracts(bytes, size + 7, 1) == 1);
    free(bytes);

    // Cut short anywhere, including inside the directory.
    for (size_t cut = 0; cut < size; cut += cut < directory ? 4099 : 1) assert(!opens(writer.file.bytes, cut));
    // Ten bytes missing from the directory, with an end record that hides it.
    bytes = copy(&writer);
    memmove(bytes + end - 10, bytes + end, 22);
    assert(!opens(bytes, size - 10));
    set32(bytes + end - 10 + 12, (uint32_t)(writer.directory.size - 10));
    assert(!opens(bytes, size - 10));
    free(bytes);
    // A directory that claims more or fewer entries than it holds.
    bytes = copy(&writer); set16(bytes + end + 8, 4); set16(bytes + end + 10, 4); assert(!opens(bytes, size)); free(bytes);
    bytes = copy(&writer); set16(bytes + end + 8, 6); set16(bytes + end + 10, 6); assert(!opens(bytes, size)); free(bytes);
    bytes = copy(&writer); set16(bytes + end + 8, 4); assert(!opens(bytes, size)); free(bytes);
    bytes = copy(&writer); set16(bytes + end + 4, 1); assert(!opens(bytes, size)); free(bytes);              // another part
    bytes = copy(&writer); set32(bytes + directory, 0x02014b51); assert(!opens(bytes, size)); free(bytes);   // not a directory record

    // ZIP64: its marker values, and its locator before the end record.
    bytes = copy(&writer); set16(bytes + end + 8, 0xFFFF); set16(bytes + end + 10, 0xFFFF); assert(!opens(bytes, size)); free(bytes);
    bytes = copy(&writer); set32(bytes + end + 16, 0xFFFFFFFF); assert(!opens(bytes, size)); free(bytes);
    bytes = copy(&writer); set32(bytes + end + 12, 0xFFFFFFFF); assert(!opens(bytes, size)); free(bytes);
    bytes = copy(&writer); set32(bytes + directory + 24, 0xFFFFFFFF); assert(!opens(bytes, size)); free(bytes);
    bytes = copy(&writer); set32(bytes + directory + 42, 0xFFFFFFFF); assert(!opens(bytes, size)); free(bytes);
    bytes = malloc(size + 20);
    memcpy(bytes, writer.file.bytes, end); memset(bytes + end, 0, 20); set32(bytes + end, 0x07064b50);
    memcpy(bytes + end + 20, writer.file.bytes + end, 22);
    assert(!opens(bytes, size + 20));
    free(bytes);

    // Encrypted, an unknown method, a stored entry whose sizes differ.
    bytes = copy(&writer); bytes[directory + 8] |= 1; assert(!opens(bytes, size)); free(bytes);
    bytes = copy(&writer); bytes[6] |= 1; assert(extracts(bytes, size, 0) == 0); free(bytes);   // only the local header says so
    bytes = copy(&writer); set16(bytes + second + 10, 12); assert(!opens(bytes, size)); free(bytes);
    bytes = copy(&writer); set16(bytes + 8, 8); assert(extracts(bytes, size, 0) == 0); free(bytes);   // the local header disagrees
    bytes = copy(&writer); set32(bytes + directory + 24, 9); assert(!opens(bytes, size)); free(bytes);

    // Content outside the file: a length or an offset that runs past the directory.
    bytes = copy(&writer); set32(bytes + second + 20, (uint32_t)size); assert(!opens(bytes, size)); free(bytes);
    bytes = copy(&writer); set32(bytes + second + 20, 0x7FFFFFFF); assert(!opens(bytes, size)); free(bytes);
    bytes = copy(&writer); set32(bytes + second + 42, (uint32_t)directory); assert(!opens(bytes, size)); free(bytes);
    bytes = copy(&writer); set32(bytes + directory + 42, (uint32_t)(directory - 20)); assert(!opens(bytes, size)); free(bytes);
    // A local header whose own lengths push the content past the directory.
    size_t local = 30 + 5 + strlen(hello);   // the second entry's local header
    bytes = copy(&writer); set16(bytes + local + 28, 0xFFFF); assert(extracts(bytes, size, 1) == 0); free(bytes);
    bytes = copy(&writer); set32(bytes + local, 0x04034b51); assert(extracts(bytes, size, 1) == 0); free(bytes);

    // Content that is not what the directory says: CRC-32 and length, stored and deflated.
    bytes = copy(&writer); bytes[30 + 5] ^= 1; assert(extracts(bytes, size, 0) == 0 && extracts(bytes, size, 1) == 1); free(bytes);
    bytes = copy(&writer); bytes[local + 30 + 11 + 100] ^= 0x10; assert(extracts(bytes, size, 1) == 0); free(bytes);
    bytes = copy(&writer); bytes[second + 16] ^= 1; assert(extracts(bytes, size, 1) == 0); free(bytes);
    bytes = copy(&writer); set32(bytes + second + 24, sizeof big - 1); assert(extracts(bytes, size, 1) == 0); free(bytes);
    bytes = copy(&writer); set32(bytes + second + 24, sizeof big + 1); assert(extracts(bytes, size, 1) == 0); free(bytes);
    bytes = copy(&writer); set32(bytes + second + 24, 16); assert(extracts(bytes, size, 1) == 0); free(bytes);
    // A deflated stream that is longer or shorter than the entry.
    bytes = copy(&writer);
    uint32_t stored = (uint32_t)(bytes[second + 20] | bytes[second + 21] << 8 | bytes[second + 22] << 16);
    set32(bytes + second + 20, stored - 5); assert(extracts(bytes, size, 1) == 0);
    set32(bytes + second + 20, stored + 5); assert(extracts(bytes, size, 1) == 0);
    free(bytes);

    // Names: none, with a NUL, too long.
    bytes = copy(&writer); bytes[directory + 46 + 1] = 0; assert(!opens(bytes, size)); free(bytes);
    bytes = copy(&writer); set16(bytes + directory + 28, 0); assert(!opens(bytes, size)); free(bytes);
    char name[ZA_MAX_NAME + 2];
    for (int extra = 0; extra < 2; extra++) {
        memset(name, 'n', sizeof name); name[ZA_MAX_NAME + extra] = 0;
        ZipWriter named = {0};
        zw_add(&named, name, hello, strlen(hello), 1, 0);
        zw_finish(&named);
        assert(opens(named.file.bytes, named.file.size) == !extra);
        zw_free(&named);
    }
    // An archive of nothing is an archive.
    ZipWriter none = {0};
    zw_finish(&none);
    assert(opens(none.file.bytes, none.file.size));
    zw_free(&none); zw_free(&writer);
    unlink(path);
    puts("zip archive: stored and deflated entries, modes and a comment; cut short, a damaged directory, ZIP64, encryption, unknown methods, "
         "content outside the file, wrong CRC-32 and lengths, bad names: PASS");
    return 0;
}
