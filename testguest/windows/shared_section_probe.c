/* Our own probe: a named shared-memory mapping one 32-bit process creates and another
 * opens by name, as a browser and its host program share a stream. With WoW64's 32-bit
 * address space at a host window (docs/WINDOWS.md) both views must be the same memory.
 *
 *   i686-w64-mingw32-clang -O2 shared_section_probe.c -o shared_section_probe.exe
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>

static const char name[] = "Local\\TolkaraSharedSectionProbe";
enum { SECTION_SIZE = 4 << 20 };

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc > 1 && !strcmp(argv[1], "child"))
    {
        HANDLE mapping = OpenFileMappingA(FILE_MAP_ALL_ACCESS, FALSE, name);
        if (!mapping) { printf("child: OpenFileMapping failed: %lu\n", GetLastError()); return 2; }
        char *view = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, SECTION_SIZE);
        if (!view) { printf("child: MapViewOfFile failed: %lu\n", GetLastError()); return 3; }
        printf("child: view at %p reads \"%s\"\n", view, view);
        BOOL ok = !strcmp(view, "from the parent") && view[SECTION_SIZE - 1] == 'z';
        strcpy(view + 64, "from the child");
        return ok ? 0 : 4;
    }

    HANDLE mapping = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, SECTION_SIZE, name);
    if (!mapping) { printf("CreateFileMapping failed: %lu\n", GetLastError()); return 1; }
    printf("CreateFileMapping: %s\n", GetLastError() == ERROR_ALREADY_EXISTS ? "already existed" : "created");
    char *view = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, SECTION_SIZE);
    if (!view) { printf("MapViewOfFile failed: %lu\n", GetLastError()); return 1; }
    strcpy(view, "from the parent");
    view[SECTION_SIZE - 1] = 'z';
    printf("parent: view at %p\n", view);

    /* a second view in this process sees the same memory */
    char *second = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, SECTION_SIZE);
    int failures = !second || strcmp(second, "from the parent");
    printf("second view at %p: %s\n", second, failures ? "FAIL" : "ok");

    char self[MAX_PATH], command[MAX_PATH + 16];
    GetModuleFileNameA(NULL, self, MAX_PATH);
    snprintf(command, sizeof(command), "\"%s\" child", self);
    STARTUPINFOA si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    if (!CreateProcessA(NULL, command, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi))
    {
        printf("CreateProcess failed: %lu\n", GetLastError());
        return 1;
    }
    DWORD code = 99;
    WaitForSingleObject(pi.hProcess, 20000);
    GetExitCodeProcess(pi.hProcess, &code);
    printf("child exit code %lu, child wrote \"%s\"\n", code, view + 64);
    failures += code != 0 || strcmp(view + 64, "from the child");
    printf("%s\n", failures ? "FAIL" : "PASS");
    return failures ? 1 : 0;
}
