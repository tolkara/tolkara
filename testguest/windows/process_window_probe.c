/* Our own fixture for windows from two Windows processes at once
 * (docs/MULTIPROCESS.md, M3): the parent shows a blue window and starts itself
 * as a child, which shows a green window for a few seconds and exits with 7.
 * Both windows paint while both processes run; the parent checks the exit
 * code. No application code is involved.
 *
 *   x86_64-w64-mingw32-clang -O2 -municode process_window_probe.c -o process_window_probe.exe -lgdi32 -luser32
 */
#include <windows.h>
#include <stdio.h>

static COLORREF fill;
static const wchar_t *label;

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam)
{
    if (message == WM_PAINT)
    {
        PAINTSTRUCT paint;
        RECT client;
        HDC dc = BeginPaint(window, &paint);
        HBRUSH brush = CreateSolidBrush(fill);
        GetClientRect(window, &client);
        FillRect(dc, &client, brush);
        DeleteObject(brush);
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, RGB(255, 255, 255));
        DrawTextW(dc, label, -1, &client, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        EndPaint(window, &paint);
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

static HWND show_window(int x, int y)
{
    WNDCLASSW class = {0};
    class.lpfnWndProc = window_proc;
    class.hInstance = GetModuleHandleW(NULL);
    class.lpszClassName = L"TolkaraProcessWindowProbe";
    class.hCursor = LoadCursorW(NULL, (const wchar_t *)IDC_ARROW);
    RegisterClassW(&class);
    HWND window = CreateWindowExW(0, class.lpszClassName, label, WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                                  x, y, 480, 320, NULL, NULL, class.hInstance, NULL);
    UpdateWindow(window);
    return window;
}

/* Pumps messages until the handle is signalled or the time runs out. */
static BOOL pump(HANDLE handle, DWORD milliseconds)
{
    DWORD start = GetTickCount();
    for (;;)
    {
        DWORD elapsed = GetTickCount() - start;
        if (elapsed >= milliseconds) return FALSE;
        DWORD result = MsgWaitForMultipleObjects(handle ? 1 : 0, &handle, FALSE, milliseconds - elapsed, QS_ALLINPUT);
        if (handle && result == WAIT_OBJECT_0) return TRUE;
        MSG message;
        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE))
        {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
}

int wmain(int argc, wchar_t **argv)
{
    if (argc == 2 && !wcscmp(argv[1], L"--child"))
    {
        fill = RGB(20, 140, 60);
        label = L"Child process window";
        HWND window = show_window(560, 140);
        printf("child: window %p\n", (void *)window);
        fflush(stdout);
        pump(NULL, 8000);
        DestroyWindow(window);
        return 7;
    }
    fill = RGB(30, 80, 200);
    label = L"Parent process window";
    HWND window = show_window(40, 100);
    printf("parent: window %p\n", (void *)window);
    fflush(stdout);
    pump(NULL, 1500);

    WCHAR path[MAX_PATH], command[MAX_PATH + 16];
    STARTUPINFOW startup = {sizeof(startup)};
    PROCESS_INFORMATION process = {0};
    DWORD code = 0;
    GetModuleFileNameW(NULL, path, MAX_PATH);
    swprintf(command, MAX_PATH + 16, L"\"%ls\" --child", path);
    if (!CreateProcessW(path, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process))
    {
        printf("FAIL: CreateProcess error=%lu\n", GetLastError());
        return 1;
    }
    BOOL ended = pump(process.hProcess, 30000);
    GetExitCodeProcess(process.hProcess, &code);
    pump(NULL, 1500);
    DestroyWindow(window);
    if (!ended || code != 7)
    {
        printf("FAIL: child ended=%d exit code=%lu\n", ended, code);
        return 1;
    }
    puts("PASS: parent and child windows, child exit status");
    return 0;
}
