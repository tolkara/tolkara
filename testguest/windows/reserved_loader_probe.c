/* Our own regression probe for the restricted-address-space Wine experiment.
 * Build with x86_64-w64-mingw32-clang. Run in an isolated Mac prefix with:
 * WINEADDRESSLIMIT=70000000000-71000000000
 * WINELARGERESERVE=70000000000-71000000000
 * WINESMALLRANGE=70300000000-703ffff0000 WINERELOCATEHINTS=1
 * This shifted 64 GiB window avoids the Mac native allocator's iPad-like
 * address range. It is a layout test, not physical-iPad compatibility proof.
 */
#include <windows.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    (void)argv;
    const ULONG_PTR low = 0x70000000000ULL, high = 0x71000000000ULL;
    const SIZE_T pool_size = 0x400000000ULL;
    const ULONG_PTR bases[] = {0x70c00000000ULL, 0x70800000000ULL, 0x703ffff0000ULL};
    const SIZE_T sizes[] = {0x400000000ULL, 0x400000000ULL, 0x400010000ULL};
    const char *names[] = {"psapi.dll", "shell32.dll"};
    int failures = 0;
    void *p;

    setvbuf(stdout, NULL, _IONBF, 0);
    p = VirtualAlloc((void *)0x60000000000ULL, 4096, MEM_RESERVE, PAGE_NOACCESS);
    printf("small below-window reservation refused: %s\n", p ? "FAIL" : "PASS");
    if (p) { failures++; VirtualFree(p, 0, MEM_RELEASE); }

    p = VirtualAlloc((void *)0x62400000000ULL, pool_size, MEM_RESERVE, PAGE_NOACCESS);
    BOOL inside = p && (ULONG_PTR)p >= low && (ULONG_PTR)p <= high - pool_size &&
                  !((ULONG_PTR)p & (pool_size - 1));
    printf("large below-window hint relocated inside: %s (%p)\n", inside ? "PASS" : "FAIL", p);
    failures += !inside;
    if (p) VirtualFree(p, 0, MEM_RELEASE);

    for (int i = 0; i < 3; i++)
    {
        p = VirtualAlloc((void *)bases[i], sizes[i], MEM_RESERVE, PAGE_NOACCESS);
        printf("pool %d: %p\n", i, p);
        if (p != (void *)bases[i]) return 2;
    }
    for (int i = 0; i < 2; i++)
    {
        HMODULE module = LoadLibraryA(names[i]);
        printf("load %s: %s (error %lu)\n", names[i], module ? "PASS" : "FAIL",
               module ? 0 : GetLastError());
        failures += !module;
        if (module) FreeLibrary(module);
    }
    for (int i = 0; i < 3; i++) VirtualFree((void *)bases[i], 0, MEM_RELEASE);
    if (argc == 1)
    {
        char exe[MAX_PATH], command[MAX_PATH + 32];
        STARTUPINFOA startup = {0};
        PROCESS_INFORMATION process = {0};
        DWORD code = 1;
        startup.cb = sizeof(startup);
        if (!GetModuleFileNameA(NULL, exe, sizeof(exe))) return 3;
        snprintf(command, sizeof(command), "\"%s\" --child", exe);
        if (!CreateProcessA(NULL, command, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &process))
            return 3;
        if (WaitForSingleObject(process.hProcess, 20000) != WAIT_OBJECT_0)
        {
            TerminateProcess(process.hProcess, 4);
            failures++;
        }
        else if (!GetExitCodeProcess(process.hProcess, &code) || code) failures++;
        printf("child address-window check: %s\n", code ? "FAIL" : "PASS");
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
    }
    return failures ? 1 : 0;
}
