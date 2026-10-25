/* Owned finite Wine handover fixture. Build the same source as parent and child;
 * remote_child.exe is selected by TOLKARA_REMOTE_PROCESS. No guest inspection. */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <wchar.h>

static uint32_t compute(void)
{
    uint32_t value = 2166136261u;
    for (uint32_t pass = 0; pass < 64; pass++)
        for (uint32_t i = 0; i < 1024 * 1024; i++)
            value = (value ^ ((i + pass) & 255)) * 16777619u;
    return value;
}

int wmain(int argc, wchar_t **argv)
{
    if (argc == 3 && !wcscmp(argv[1], L"--child")) {
        HANDLE output = (HANDLE)(uintptr_t)_wcstoui64(argv[2], NULL, 16);
        uint32_t value = compute();
        DWORD written = 0;
        BOOL ok = WriteFile(output, &value, sizeof value, &written, NULL);
        CloseHandle(output);
        return ok && written == sizeof value ? 73 : 2;
    }
    /* Optional unique gate path lets both iPad runtimes prepare before spawning.
     * Waiting is bounded and grants no background execution by itself. */
    if (argc >= 2) {
        puts("handover parent: waiting for unique gate"); fflush(stdout);
        ULONGLONG start = GetTickCount64();
        while (GetFileAttributesW(argv[1]) == INVALID_FILE_ATTRIBUTES) {
            if (GetTickCount64() - start > 600000) {
                puts("FAIL: handover gate timeout"); return 3;
            }
            Sleep(100);
        }
    }
    SECURITY_ATTRIBUTES security = { sizeof security, NULL, TRUE };
    HANDLE input = NULL, output = NULL;
    if (!CreatePipe(&input, &output, &security, 0) ||
        !SetHandleInformation(input, HANDLE_FLAG_INHERIT, 0)) return 4;
    const wchar_t *child_path = argc >= 3 ? argv[2] : L"remote_child.exe";
    WCHAR command[1024];
    if (swprintf(command, 1024, L"\"%ls\" --child %llx", child_path, (unsigned long long)(uintptr_t)output) < 0) {
        CloseHandle(input); CloseHandle(output); return 7;
    }
    STARTUPINFOW startup = {0}; startup.cb = sizeof startup;
    PROCESS_INFORMATION process = {0};
    if (!CreateProcessW(child_path, command, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &process)) {
        printf("FAIL: CreateProcess error=%lu\n", GetLastError());
        CloseHandle(input); CloseHandle(output); return 5;
    }
    CloseHandle(output);
    DWORD waited = WaitForSingleObject(process.hProcess, 30000), code = 0;
    GetExitCodeProcess(process.hProcess, &code);
    uint32_t value = 0;
    DWORD read = 0, available = 0;
    BOOL received = waited == WAIT_OBJECT_0 && PeekNamedPipe(input, NULL, 0, NULL, &available, NULL)
        && available == sizeof value && ReadFile(input, &value, sizeof value, &read, NULL)
        && read == sizeof value;
    CloseHandle(input); CloseHandle(process.hThread); CloseHandle(process.hProcess);
    /* Independently calculated reference for the fixed input, not a second job. */
    if (!received || code != 73 || value != 0x4bfc9dc5u) {
        printf("FAIL: wait=%lu exit=%lu received=%d checksum=%08x\n", waited, code, received, (unsigned)value);
        return 6;
    }
    puts("PASS: child computed 64 MiB, inherited pipe returned checksum, exit 73");
    return 0;
}
