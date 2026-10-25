/* Our own probe: a thread one 32-bit process starts in another (CreateRemoteThread),
 * as Chromium does to make a hung child write a dump, and the thread ids new threads
 * see. With WoW64's 32-bit address space at a host window (docs/WINDOWS.md) the
 * remote thread must still start as 32-bit code at the child's own address.
 *
 *   i686-w64-mingw32-clang -O2 remote_thread_probe.c -o remote_thread_probe.exe
 */
#include <windows.h>
#include <winternl.h>
#include <stdio.h>
#include <string.h>

static DWORD WINAPI report_ids(void *arg)
{
    DWORD api = GetCurrentThreadId();
    DWORD teb = (DWORD)(ULONG_PTR)((CLIENT_ID *)((char *)NtCurrentTeb() + 0x20))->UniqueThread;
    printf("thread %lu: GetCurrentThreadId %lu, TEB %lu %s\n", (unsigned long)(ULONG_PTR)arg,
           api, teb, api && api == teb ? "ok" : "MISMATCH");
    return api && api == teb ? 0 : 1;
}

int main(int argc, char **argv)
{
    if (argc > 1 && !strcmp(argv[1], "child"))
    {
        Sleep(8000);
        return 5;
    }

    int failures = 0;
    setvbuf(stdout, NULL, _IONBF, 0);
    for (int i = 1; i <= 4; i++)
    {
        HANDLE thread = CreateThread(NULL, 0, report_ids, (void *)(ULONG_PTR)i, 0, NULL);
        DWORD code = 1;
        WaitForSingleObject(thread, 5000);
        GetExitCodeThread(thread, &code);
        failures += code != 0;
        CloseHandle(thread);
    }

    char self[MAX_PATH], command[MAX_PATH + 16];
    GetModuleFileNameA(NULL, self, MAX_PATH);
    snprintf(command, sizeof(command), "\"%s\" child", self);
    STARTUPINFOA si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    /* "suspended": the thread arrives before the child has run, as when a parent
       prepares a child it created suspended */
    BOOL suspended = argc > 1 && !strcmp(argv[1], "suspended");
    if (!CreateProcessA(NULL, command, NULL, NULL, FALSE, suspended ? CREATE_SUSPENDED : 0, NULL, NULL, &si, &pi))
    {
        printf("CreateProcess failed: %lu\n", GetLastError());
        return 1;
    }
    if (!suspended) Sleep(1500);

    /* kernel32 is at the same address in both processes */
    LPTHREAD_START_ROUTINE start = (LPTHREAD_START_ROUTINE)GetProcAddress(GetModuleHandleA("kernel32"), "Sleep");
    HANDLE remote = CreateRemoteThread(pi.hProcess, NULL, 0, start, (void *)100, 0, NULL);
    if (!remote)
    {
        printf("CreateRemoteThread failed: %lu\n", GetLastError());
        failures++;
    }
    else
    {
        DWORD code = 0xdead, wait = WaitForSingleObject(remote, 5000);
        GetExitCodeThread(remote, &code);
        printf("remote thread at %p: wait %lu, exit code %lu\n", (void *)start, wait, code);
        failures += wait != WAIT_OBJECT_0 || code != 0;
    }

    if (suspended) ResumeThread(pi.hThread);
    DWORD child = 0;
    WaitForSingleObject(pi.hProcess, 15000);
    GetExitCodeProcess(pi.hProcess, &child);
    printf("child exit code %lu (5 expected)\n", child);
    failures += child != 5;
    printf("%s\n", failures ? "FAIL" : "PASS");
    return failures ? 1 : 0;
}
