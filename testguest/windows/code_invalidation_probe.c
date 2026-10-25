#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static DWORD WINAPI run(void *arg) {
    unsigned char *code = VirtualAlloc(NULL, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!code) return 1;
    for (unsigned i = 0; i < 100; ++i) {
        DWORD old;
        uint32_t value = (uint32_t)(uintptr_t)arg * 1000 + i;
        if (!VirtualProtect(code, 4096, PAGE_READWRITE, &old)) return 2;
        code[0] = 0xb8; /* Our x86-64 fixture: mov eax, imm32; ret. */
        memcpy(code + 1, &value, sizeof(value));
        code[5] = 0xc3;
        if (!VirtualProtect(code, 4096, PAGE_EXECUTE_READ, &old)) return 3;
        if (!FlushInstructionCache(GetCurrentProcess(), code, 6)) return 4;
        if (((uint32_t (*)(void))code)() != value) return 5;
    }
    return VirtualFree(code, 0, MEM_RELEASE) ? 0 : 6;
}

int main(void) {
    HANDLE threads[8];
    for (unsigned i = 0; i < 8; ++i) {
        threads[i] = CreateThread(NULL, 0, run, (void*)(uintptr_t)(i + 1), 0, NULL);
        if (!threads[i]) return 10;
    }
    if (WaitForMultipleObjects(8, threads, TRUE, 30000) != WAIT_OBJECT_0) return 11;
    for (unsigned i = 0; i < 8; ++i) {
        DWORD result;
        if (!GetExitCodeThread(threads[i], &result) || result) return 12;
        CloseHandle(threads[i]);
    }
    puts("Concurrent owned-code invalidation probe passed");
    return 0;
}
