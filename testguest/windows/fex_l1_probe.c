#include <windows.h>
#include <stdint.h>
#include <stdio.h>
extern uint32_t f(uint32_t);
extern uint32_t g(uint32_t);
static DWORD WINAPI worker(void *p) {
    uint32_t x = (uint32_t)(uintptr_t)p, expected = x;
    uint32_t (*volatile a)(uint32_t) = f;
    uint32_t (*volatile b)(uint32_t) = g;
    for (unsigned i = 0; i < 1000000; i++) {
        x = b(a(x));
        expected = (expected * 17u + 3u) * 23u + 7u;
        if (x != expected) return 1;
    }
    return 0;
}
int main(void) {
    if (((uintptr_t)f & 65535) != ((uintptr_t)g & 65535)) return 2;
    HANDLE t[8];
    for (unsigned i=0;i<8;i++) { t[i]=CreateThread(0,0,worker,(void *)(uintptr_t)(i+1),0,0); if (!t[i]) return 3; }
    if (WaitForMultipleObjects(8,t,TRUE,30000) != WAIT_OBJECT_0) return 4;
    for (unsigned i=0;i<8;i++) { DWORD code; if (!GetExitCodeThread(t[i],&code)||code) return 5; CloseHandle(t[i]); }
    puts("L1 collision/thread probe passed");
    return 0;
}
