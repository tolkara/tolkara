/* Our own probe: large aligned reservations asked at random high addresses, the way
 * allocators that keep pools on aligned boundaries try first. On a host whose address
 * space ends long before Windows' (an iPadOS app has 64 GB), Wine can make them at a
 * reachable address with the same alignment (WINERELOCATEHINTS); this checks the
 * alignment, that they do not overlap, and that committed pages in them work.
 *
 *   x86_64-w64-mingw32-clang -O2 aligned_hint_probe.c -o aligned_hint_probe.exe
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define GiB (1ull << 30)
#define KiB (1ull << 10)

struct request { const char *name; ULONGLONG hint, size, align, offset; char *got; };

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    struct request requests[] = {
        { "16G at 16G", 0x3a5c00000000ull, 16 * GiB, 16 * GiB, 0 },
        { "16G+64K at 16G-64K", 0x3b6400000000ull + 16 * GiB - 64 * KiB, 16 * GiB + 64 * KiB, 16 * GiB, 16 * GiB - 64 * KiB },
        { "16G at 16G (another)", 0x3c0000000000ull, 16 * GiB, 16 * GiB, 0 },
    };
    int count = sizeof(requests) / sizeof(requests[0]), failures = 0;

    for (int i = 0; i < count; i++)
    {
        struct request *r = &requests[i];
        r->got = VirtualAlloc((void *)(ULONG_PTR)r->hint, r->size, MEM_RESERVE, PAGE_NOACCESS);
        BOOL aligned = r->got && ((ULONG_PTR)r->got & (r->align - 1)) == r->offset;
        printf("%-22s hint %p -> %p %s\n", r->name, (void *)(ULONG_PTR)r->hint, r->got,
               !r->got ? "FAILED" : aligned ? "aligned" : "MISALIGNED");
        failures += !aligned;
    }
    for (int i = 0; i < count; i++)
        for (int j = i + 1; j < count; j++)
        {
            struct request *a = &requests[i], *b = &requests[j];
            if (a->got && b->got && a->got < b->got + b->size && b->got < a->got + a->size)
            {
                printf("%s and %s overlap\n", a->name, b->name);
                failures++;
            }
        }
    /* With WINEPHANTOMRANGE the guarded pool (16G+64K) is recorded without host memory:
       it must sit in that range and refuse commits, and its release must work. */
    const char *phantom = getenv("WINEPHANTOMRANGE");
    ULONGLONG phantom_start = 0, phantom_end = 0;
    if (phantom) sscanf(phantom, "%llx-%llx", &phantom_start, &phantom_end);
    for (int i = 0; i < count; i++)
    {
        struct request *r = &requests[i];
        BOOL guarded = r->offset != 0, inside = r->got && (ULONG_PTR)r->got >= phantom_start &&
                       (ULONG_PTR)r->got + r->size <= phantom_end;
        if (!phantom || !r->got) continue;
        if (guarded != inside)
        {
            printf("%-22s %s the phantom range: FAIL\n", r->name, inside ? "inside" : "outside");
            failures++;
        }
        if (!guarded) continue;
        void *commit = VirtualAlloc(r->got + 4096, 4096, MEM_COMMIT, PAGE_READWRITE);
        printf("%-22s commit refused %s\n", r->name, commit ? "FAIL" : "ok");
        failures += commit != NULL;
        BOOL released = VirtualFree(r->got, 0, MEM_RELEASE);
        MEMORY_BASIC_INFORMATION info = {0};
        BOOL queried = VirtualQuery(r->got, &info, sizeof(info)) == sizeof(info);
        printf("%-22s release %s\n", r->name, released && queried && info.State == MEM_FREE ? "ok" : "FAIL");
        failures += !(released && queried && info.State == MEM_FREE);
        r->got = NULL;
    }
    /* negative control: a small reservation at an address the host cannot reach still fails */
    void *exact = VirtualAlloc((void *)(ULONG_PTR)0x3a0000000000ull, 64 << 20, MEM_RESERVE, PAGE_NOACCESS);
    printf("%-22s %s\n", "small unreachable", exact ? "relocated: FAIL" : "refused ok");
    failures += exact != NULL;
    for (int i = 0; i < count; i++)
    {
        struct request *r = &requests[i];
        if (!r->got) continue;
        char *page = VirtualAlloc(r->got + r->size - 4096, 4096, MEM_COMMIT, PAGE_READWRITE);
        if (page) { strcpy(page, r->name); }
        MEMORY_BASIC_INFORMATION info = {0};
        BOOL queried = VirtualQuery(r->got + GiB, &info, sizeof(info)) == sizeof(info);
        BOOL ok = page == r->got + r->size - 4096 && !strcmp(page, r->name) && queried &&
                  info.State == MEM_RESERVE && info.AllocationBase == r->got;
        printf("%-22s commit/query %s\n", r->name, ok ? "ok" : "FAIL");
        failures += !ok;
    }
    printf("%s\n", failures ? "FAIL" : "PASS");
    return failures ? 1 : 0;
}
