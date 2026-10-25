/* Native ARM64 smoke test: no CRT or ARM64EC startup dependencies.
 * Build with -nostdlib -Wl,--entry,mainCRTStartup
 * -Wl,--section-alignment=0x10000 -lkernel32. Place the companion DLL
 * beside this executable as aligned_image_probe.dll. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

static void say(const char *text, DWORD size)
{
    DWORD written;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text, size, &written, NULL);
}
#define SAY(text) say(text, sizeof(text) - 1)

void mainCRTStartup(void)
{
    HMODULE previous[8];
    char mode[2];
    int no_reuse = GetEnvironmentVariableA("WINEJITPOOLNOREUSE", mode, sizeof(mode)) == 1 && mode[0] == '1';
    for (unsigned i = 0; i < 8; ++i) {
        HMODULE module = LoadLibraryW(L"aligned_image_probe.dll");
        if (!module) { SAY("LoadLibrary failed\n"); ExitProcess(1); }
        if (no_reuse) {
            for (unsigned j = 0; j < i; ++j) {
                if (previous[j] == module) { SAY("retired image address reused\n"); ExitProcess(4); }
            }
        }
        previous[i] = module;
        int (*value)(void) = (int (*)(void))GetProcAddress(module, "aligned_probe_value");
        if (!value) { SAY("GetProcAddress failed\n"); ExitProcess(2); }
        if (value() != 7349) { SAY("aligned native DLL FAIL\n"); ExitProcess(3); }
        if (!FreeLibrary(module)) { SAY("FreeLibrary failed\n"); ExitProcess(5); }
    }
    SAY("aligned native DLL reload PASS\n");
    ExitProcess(0);
}
