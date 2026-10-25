/* Owned native ARM64 Windows fixture; no CRT. The paired test host supplies
 * real native pages above Wine's artificial native address limit. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#define SAY(s) do { DWORD written; WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),s,sizeof(s)-1,&written,NULL); } while(0)
void mainCRTStartup(void) {
    const SIZE_T pool=(SIZE_T)16<<30, guard=0x10000;
    void *ranges[4];
    for(unsigned i=0;i<4;i++) {
        SIZE_T hint=0x300000000000ULL + (SIZE_T)i*(32ULL<<30)-guard;
        ranges[i]=VirtualAlloc((void *)hint,pool+guard,MEM_RESERVE,PAGE_NOACCESS);
        if(!ranges[i] || (((SIZE_T)ranges[i]+guard)&(pool-1))) { SAY("FAIL reserve/alignment\n"); ExitProcess(1); }
        void *page=(char *)ranges[i]+guard;
        if(VirtualAlloc(page,0x4000,MEM_COMMIT,PAGE_READWRITE)!=page) { SAY("FAIL commit\n"); ExitProcess(2); }
        *(volatile ULONGLONG *)page=7349+i;
        MEMORY_BASIC_INFORMATION info;
        if(!VirtualQuery(page,&info,sizeof(info)) || info.State!=MEM_COMMIT || info.Protect!=PAGE_READWRITE) { SAY("FAIL query\n"); ExitProcess(3); }
        DWORD old;
        if(!VirtualProtect(page,0x4000,PAGE_READONLY,&old) || old!=PAGE_READWRITE) { SAY("FAIL protect\n"); ExitProcess(4); }
    }
    for(unsigned i=0;i<4;i++) {
        if(*(volatile ULONGLONG *)((char *)ranges[i]+guard)!=7349+i) { SAY("FAIL isolation\n"); ExitProcess(5); }
        if(!VirtualFree(ranges[i],0,MEM_RELEASE)) { SAY("FAIL release\n"); ExitProcess(6); }
        MEMORY_BASIC_INFORMATION freed;
        if(!VirtualQuery(ranges[i],&freed,sizeof(freed)) || freed.State!=MEM_FREE ||
           !freed.RegionSize || (SIZE_T)freed.BaseAddress+freed.RegionSize<(SIZE_T)freed.BaseAddress) {
            SAY("FAIL query after release\n"); ExitProcess(7);
        }
    }
    SAY("PASS software pool Wine reserve/commit/query/protect/release\n"); ExitProcess(0);
}
