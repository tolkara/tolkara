#include <windows.h>
#include <stdint.h>
#include <stdio.h>
extern uint32_t long_block(uint32_t);
static DWORD WINAPI run(void *arg) {
    for(unsigned pass=0;pass<10;pass++) {
        uint32_t x=(uint32_t)(uintptr_t)arg+pass, expected=x;
        for(unsigned i=0;i<12000;i++) expected=expected*17u+3u;
        if(long_block(x)!=expected)return 1;
    }
    return 0;
}
int main(void) {
    HANDLE threads[8];
    for(unsigned i=0;i<8;i++){ threads[i]=CreateThread(0,0,run,(void*)(uintptr_t)(i+1),0,0);if(!threads[i])return 2; }
    if(WaitForMultipleObjects(8,threads,TRUE,30000)!=WAIT_OBJECT_0)return 3;
    for(unsigned i=0;i<8;i++){DWORD code;if(!GetExitCodeThread(threads[i],&code)||code)return 4;CloseHandle(threads[i]);}
    puts("Long decoder-block/thread probe passed");
    return 0;
}
