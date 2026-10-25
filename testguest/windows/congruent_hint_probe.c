#include <windows.h>
#include <stdio.h>
int main(void) {
    const ULONG_PTR bases[] = {0x70c00000000ULL,0x70800000000ULL,0x703ffff0000ULL,0x70000000000ULL};
    const SIZE_T sizes[] = {0x400000000ULL,0x400000000ULL,0x400010000ULL,0x300000000ULL};
    setvbuf(stdout,NULL,_IONBF,0);
    for(unsigned i=0;i<4;i++) if(VirtualAlloc((void*)bases[i],sizes[i],MEM_RESERVE,PAGE_NOACCESS)!=(void*)bases[i]) { puts("Setup failed");return 2; }
    const SIZE_T size=0x20000000;
    void *p=VirtualAlloc((void*)0x60000000000ULL,size,MEM_RESERVE,PAGE_NOACCESS);
    BOOL ok=p && (ULONG_PTR)p>=0x70300000000ULL && (ULONG_PTR)p+size<=0x703ffff0000ULL && !((ULONG_PTR)p&(size-1));
    printf("Congruent hint in remaining ordinary region: %s\n",ok?"PASS":"FAIL");
    if(ok) {
        volatile DWORD *sentinel=VirtualAlloc(p,4096,MEM_COMMIT,PAGE_READWRITE);
        if(!sentinel) return 3;
        *sentinel=0x13572468;
        void *q=VirtualAlloc((void*)0x60000000000ULL,size,MEM_RESERVE,PAGE_NOACCESS);
        BOOL distinct=q && q!=p && (ULONG_PTR)q>=0x70300000000ULL && (ULONG_PTR)q+size<=0x703ffff0000ULL && !((ULONG_PTR)q&(size-1)) && *sentinel==0x13572468;
        printf("Second hint preserves existing view: %s\n",distinct?"PASS":"FAIL");
        ok=ok && distinct;
        if(q)VirtualFree(q,0,MEM_RELEASE);
    }
    if(p)VirtualFree(p,0,MEM_RELEASE);
    for(unsigned i=0;i<4;i++)VirtualFree((void*)bases[i],0,MEM_RELEASE);
    return ok?0:1;
}
