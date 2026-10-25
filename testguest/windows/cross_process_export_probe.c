/* Owned cross-process system-export fixture; no third-party code or memory is
 * inspected. Parent passes a GetCurrentProcessId function pointer through an
 * inherited pipe. Child calls it and checks that it identifies the child.
 * Build with x86_64-w64-mingw32-clang -municode -O2. */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <wchar.h>

int wmain(int argc, wchar_t **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc == 3 && !wcscmp(argv[1], L"--child")) {
        HANDLE input = (HANDLE)(uintptr_t)_wcstoui64(argv[2], NULL, 16);
        uintptr_t address = 0;
        DWORD received = 0;
        BOOL ok = ReadFile(input, &address, sizeof address, &received, NULL);
        CloseHandle(input);
        if (!ok || received != sizeof address) return 2;
        FARPROC local = GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "GetCurrentProcessId");
        DWORD expected = GetCurrentProcessId();
        printf("child: own export=%p parent export=%p pid=%lu\n",
               (void *)local, (void *)address, (unsigned long)expected);
        DWORD actual = ((DWORD (WINAPI *)(void))address)();
        printf("child: inherited export returned pid=%lu (%s)\n",
               (unsigned long)actual, actual == expected ? "PASS" : "FAIL");
        return actual == expected ? 0 : 3;
    }
    HANDLE input = NULL, output = NULL;
    SECURITY_ATTRIBUTES security = { sizeof security, NULL, TRUE };
    if (!CreatePipe(&input, &output, &security, 0)) return 4;
    if (!SetHandleInformation(output, HANDLE_FLAG_INHERIT, 0)) return 5;
    WCHAR path[MAX_PATH], command[MAX_PATH + 80];
    if (argc == 2) {
        if (wcslen(argv[1]) >= MAX_PATH) return 6;
        wcscpy(path, argv[1]);
    } else if (!GetModuleFileNameW(NULL, path, MAX_PATH)) return 6;
    if (swprintf(command, MAX_PATH + 80, L"\"%ls\" --child %llx", path,
                 (unsigned long long)(uintptr_t)input) < 0) return 7;
    STARTUPINFOW startup = {0}; startup.cb = sizeof startup;
    PROCESS_INFORMATION process = {0};
    if (!CreateProcessW(path, command, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &process)) {
        printf("FAIL: CreateProcess error=%lu\n", GetLastError()); return 8;
    }
    CloseHandle(input);
    uintptr_t address = (uintptr_t)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "GetCurrentProcessId");
    DWORD written = 0;
    BOOL sent = address && WriteFile(output, &address, sizeof address, &written, NULL);
    CloseHandle(output);
    DWORD wait = WaitForSingleObject(process.hProcess, 30000), code = 0;
    BOOL exited = GetExitCodeProcess(process.hProcess, &code);
    CloseHandle(process.hThread); CloseHandle(process.hProcess);
    printf("parent: wait=%lu child exit=%lu\n", wait, code);
    return sent && written == sizeof address && wait == WAIT_OBJECT_0 && exited && code == 0 ? 0 : 9;
}
