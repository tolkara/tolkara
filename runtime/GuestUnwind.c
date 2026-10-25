#include "GuestUnwind.h"
#include <dlfcn.h>
#include <stdatomic.h>
#include <string.h>

// Darwin libunwind SPI ABI, documented in LLVM's libunwind_ext.h. This is
// the lookup used for images placed outside dyld, including compact unwind.
typedef struct {
    uintptr_t header, dwarf;
    size_t dwarf_size;
    uintptr_t compact;
    size_t compact_size;
} NGUnwindSections;
typedef int (*NGUnwindFinder)(uintptr_t, NGUnwindSections *);
typedef int (*NGUnwindRegistration)(NGUnwindFinder);
// The executable and up to 64 carried libraries in each of 8 process slots.
enum { NG_UNWIND_IMAGES = 1 + 64 * 8 };
static struct {
    NGUnwindSections sections;
    struct { uintptr_t start, size; } code[GI_MAX_SEGMENTS];
    size_t count;
} images[NG_UNWIND_IMAGES];
static atomic_uint image_count;
static NGUnwindRegistration remove_finder;

static int find_sections(uintptr_t pc, NGUnwindSections *out) {
    unsigned count = atomic_load_explicit(&image_count, memory_order_acquire);
    for (unsigned i = 0; i < count; ++i)
        for (size_t j = 0; j < images[i].count; ++j)
            if (pc >= images[i].code[j].start &&
                pc - images[i].code[j].start < images[i].code[j].size) {
                *out = images[i].sections;
                return 1;
            }
    return 0;
}
static bool section_valid(const GuestImage *image, uint64_t address, uint64_t size, uint64_t slide) {
    if (!size) return !address;
    if (address > UINTPTR_MAX - slide || size > UINTPTR_MAX - (address + slide)) return false;
    for (size_t i = 0; i < image->segment_count; ++i) {
        const GISegment *s = &image->segments[i];
        if ((s->prot & GM_READ) && address >= s->address &&
            address - s->address <= s->file_size && size <= s->file_size - (address - s->address)) return true;
    }
    return false;
}
bool ng_unwind_add(const GuestImage *image, uint64_t slide) {
    if (!image || image->segment_count > GI_MAX_SEGMENTS ||
        image->header_address > UINTPTR_MAX - slide ||
        !section_valid(image, image->unwind_address, image->unwind_size, slide) ||
        !section_valid(image, image->eh_frame_address, image->eh_frame_size, slide)) return false;
    if (!image->unwind_size && !image->eh_frame_size) return true;
    unsigned index = atomic_load_explicit(&image_count, memory_order_relaxed);
    if (index == NG_UNWIND_IMAGES) return false;
    uintptr_t header = image->header_address + slide;
    for (unsigned i = 0; i < index; ++i) if (images[i].sections.header == header) return false;
    memset(&images[index], 0, sizeof images[index]);
    for (size_t i = 0; i < image->segment_count; ++i) {
        const GISegment *s = &image->segments[i];
        if (!(s->prot & GM_EXEC) || !s->size) continue;
        if (s->address > UINTPTR_MAX - slide || s->size > UINTPTR_MAX - (s->address + slide)) return false;
        size_t n = images[index].count++;
        images[index].code[n].start = s->address + slide;
        images[index].code[n].size = s->size;
    }
    if (!images[index].count) return false;
    images[index].sections = (NGUnwindSections){header,
        image->eh_frame_size ? image->eh_frame_address + slide : 0, (size_t)image->eh_frame_size,
        image->unwind_size ? image->unwind_address + slide : 0, (size_t)image->unwind_size};
    if (!remove_finder) {
        NGUnwindRegistration add = (NGUnwindRegistration)dlsym(RTLD_DEFAULT, "__unw_add_find_dynamic_unwind_sections");
        NGUnwindRegistration remove = (NGUnwindRegistration)dlsym(RTLD_DEFAULT, "__unw_remove_find_dynamic_unwind_sections");
        if (!add || !remove || add(find_sections)) return false;
        remove_finder = remove;
    }
    atomic_store_explicit(&image_count, index + 1, memory_order_release);
    return true;
}
bool ng_unwind_reset(void) {
    if (remove_finder && remove_finder(find_sections)) return false;
    remove_finder = NULL;
    atomic_store_explicit(&image_count, 0, memory_order_release);
    return true;
}
