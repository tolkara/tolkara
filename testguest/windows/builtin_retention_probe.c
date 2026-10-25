/* Owned native ARM64 fixture: prepared-pool builtin retention must not pin
 * application DLLs. Run with WINEJITPOOLNOREUSE=0 and =1. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static void fail(const char *message, DWORD length)
{
    DWORD written;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), message, length, &written, NULL);
    ExitProcess(1);
}
#define CHECK(condition, message) do { if (!(condition)) fail(message, sizeof(message)-1); } while (0)
void mainCRTStartup(void)
{
    char mode[2];
    BOOL retain = GetEnvironmentVariableA("WINEJITPOOLNOREUSE", mode, 2) == 1 && mode[0] == '1';
    HMODULE first = NULL;
    CHECK(!GetModuleHandleW(L"cryptnet.dll"), "builtin already loaded\n");
    for (unsigned i = 0; i < 32; ++i) {
        HMODULE module = LoadLibraryW(L"cryptnet.dll");
        CHECK(module, "builtin load failed\n");
        if (!first) first = module;
        CHECK(!retain || module == first, "retained builtin moved\n");
        CHECK(FreeLibrary(module), "builtin free failed\n");
        CHECK(!!GetModuleHandleW(L"cryptnet.dll") == !!retain, "builtin lifetime mismatch\n");
        module = LoadLibraryW(L"aligned_image_probe.dll");
        CHECK(module, "owned application DLL load failed\n");
        CHECK(FreeLibrary(module), "owned application DLL free failed\n");
        CHECK(!GetModuleHandleW(L"aligned_image_probe.dll"), "application DLL incorrectly pinned\n");
    }
    DWORD written;
    const char result[] = "builtin retention PASS\n";
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), result, sizeof(result)-1, &written, NULL);
    ExitProcess(0);
}
