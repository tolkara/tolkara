#include <windows.h>
static HRGN handles[65536];
static void fail(void) { ExitProcess(1); }
void mainCRTStartup(void) {
    DWORD n=0,written;
    for (;n<65536;n++) { handles[n]=CreateRectRgn(0,0,2,2); if(!handles[n])break; }
    if(n<60000 || n==65536)fail();
    for(DWORD i=0;i<n;i++)if(!DeleteObject(handles[i]))fail();
    for(DWORD i=0;i<70000;i++) { HRGN h=CreateRectRgn(0,0,2,2);if(!h || !DeleteObject(h))fail(); }
    static const char result[]="PASS GDI exhaustion, release and 70000 reuse cycles\n";
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),result,sizeof(result)-1,&written,0);
    ExitProcess(0);
}
