/* Owned x64 fixture: vectored callbacks and context restoration after faults.
 * Build without a CRT, using mainCRTStartup as the entry point. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static volatile LONG seen, faults;
extern void fault_read(void *);
extern char fault_resume;
__asm__(".text\n.globl fault_read\nfault_read:\nmovl (%rcx), %eax\n.globl fault_resume\nfault_resume:\nret\n");
static LONG CALLBACK observer(EXCEPTION_POINTERS *p) {
    if (!p || !p->ExceptionRecord || !p->ContextRecord) ExitProcess(2);
    if (p->ExceptionRecord->ExceptionCode == 0xe0424242) InterlockedIncrement(&seen);
    return EXCEPTION_CONTINUE_SEARCH;
}
static LONG CALLBACK recover(EXCEPTION_POINTERS *p) {
    if (p->ExceptionRecord->ExceptionCode == 0xe0424242) return EXCEPTION_CONTINUE_EXECUTION;
    if (p->ExceptionRecord->ExceptionCode == EXCEPTION_ACCESS_VIOLATION) {
        if (p->ExceptionRecord->ExceptionInformation[0] != 0) ExitProcess(5);
        p->ContextRecord->Rip = (DWORD64)&fault_resume;
        InterlockedIncrement(&faults);
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    return EXCEPTION_CONTINUE_SEARCH;
}
void mainCRTStartup(void) {
    PVOID r=AddVectoredExceptionHandler(0,recover), o=AddVectoredExceptionHandler(1,observer);
    if (!r || !o) ExitProcess(3);
    for (int i=0;i<32;i++) RaiseException(0xe0424242,0,0,0);
    void *page = VirtualAlloc(0,4096,MEM_RESERVE|MEM_COMMIT,PAGE_NOACCESS);
    if (!page) ExitProcess(6);
    for (int i=0;i<32;i++) fault_read(page);
    if (faults!=32) ExitProcess(7);
    VirtualFree(page,0,MEM_RELEASE);
    if (seen!=32) ExitProcess(4);
    RemoveVectoredExceptionHandler(o); RemoveVectoredExceptionHandler(r);
    DWORD n; const char msg[]="x64 vectored exception callback PASS\n";
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),msg,sizeof(msg)-1,&n,0);
    ExitProcess(0);
}
