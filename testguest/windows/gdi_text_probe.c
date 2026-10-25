/* Our own probe: what a program sees when it measures text the usual way. The
 * system UI fonts (SPI_GETNONCLIENTMETRICS), the screen DC and its resolution,
 * the monitors, and for each UI font: create it, select it into a memory DC
 * (with and without a DIB section), and measure a string. Every result is
 * printed with its success value, so runs on the Mac and on the iPad compare
 * line by line (docs/MULTIPROCESS.md, "Two apps").
 *
 *   x86_64-w64-mingw32-clang -O2 -municode gdi_text_probe.c -o gdi_text_probe.exe -lgdi32 -luser32 -lshcore
 */
#define _WIN32_WINNT 0x0A00
#define WINVER 0x0A00
#include <windows.h>
#include <shellscalingapi.h>
#include <stdio.h>

static void measure(const wchar_t *what, const LOGFONTW *logfont, BOOL with_dib)
{
    HDC screen = GetDC(NULL), dc = CreateCompatibleDC(screen);
    HFONT font = CreateFontIndirectW(logfont), previous_font;
    HBITMAP bitmap = NULL, previous_bitmap = NULL;
    TEXTMETRICW metrics = {0};
    SIZE size = {0};
    ABC abc = {0};
    void *bits = NULL;
    BOOL got_metrics, got_extent, got_abc;
    static const wchar_t text[] = L"Steam Library 0123456789";

    if (with_dib)
    {
        BITMAPINFO info = {{sizeof(BITMAPINFOHEADER), 256, -64, 1, 32, BI_RGB}};
        bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &bits, NULL, 0);
        if (bitmap) previous_bitmap = SelectObject(dc, bitmap);
    }
    previous_font = SelectObject(dc, font);
    got_metrics = GetTextMetricsW(dc, &metrics);
    got_extent = GetTextExtentPoint32W(dc, text, lstrlenW(text), &size);
    got_abc = GetCharABCWidthsW(dc, L'S', L'S', &abc);
    wprintf(L"%ls%ls: \"%ls\" lfHeight %ld weight %ld | font %p screen %p dc %p%ls | metrics %d height %ld ascent %ld ave %ld"
            L" | extent %d %ldx%ld | abc %d %d/%u/%d\n",
            what, with_dib ? L" (DIB)" : L"", logfont->lfFaceName, logfont->lfHeight, logfont->lfWeight,
            font, screen, dc, with_dib ? (bitmap ? L" dib ok" : L" dib FAILED") : L"",
            got_metrics, metrics.tmHeight, metrics.tmAscent, metrics.tmAveCharWidth,
            got_extent, size.cx, size.cy, got_abc, abc.abcA, abc.abcB, abc.abcC);
    SelectObject(dc, previous_font);
    if (previous_bitmap) SelectObject(dc, previous_bitmap);
    if (bitmap) DeleteObject(bitmap);
    DeleteObject(font);
    DeleteDC(dc);
    ReleaseDC(NULL, screen);
}

static BOOL CALLBACK monitor(HMONITOR handle, HDC dc, RECT *rect, LPARAM unused)
{
    MONITORINFOEXW info = {.cbSize = sizeof(info)};
    BOOL got = GetMonitorInfoW(handle, (MONITORINFO *)&info);
    wprintf(L"monitor %p: info %d \"%ls\" (%ld,%ld)-(%ld,%ld) work (%ld,%ld)-(%ld,%ld) flags %lx\n", handle, got,
            info.szDevice, info.rcMonitor.left, info.rcMonitor.top, info.rcMonitor.right, info.rcMonitor.bottom,
            info.rcWork.left, info.rcWork.top, info.rcWork.right, info.rcWork.bottom, info.dwFlags);
    return TRUE;
}

int wmain(int argc, wchar_t **argv)
{
    /* a child's console may be another app's: its report goes to a file */
    if (argc > 1 && !lstrcmpW(argv[1], L"child")) _wfreopen(L"gdi_child.txt", L"w, ccs=UTF-8", stdout);
    /* "--spawn": this process takes the desktop (as steam.exe does before its browser), then
     * starts itself as a child that runs the checks; in Tolkara's two apps the child runs in
     * the second app (TOLKARA_REMOTE_PROCESS=gdi_text_probe.exe). */
    if (argc > 1 && !lstrcmpW(argv[1], L"--spawn"))
    {
        wchar_t path[MAX_PATH], command[MAX_PATH + 16];
        STARTUPINFOW startup = {.cb = sizeof(startup)};
        PROCESS_INFORMATION process;
        HDC screen = GetDC(NULL);
        DWORD code = 0;
        wprintf(L"parent: desktop %p screen dc %p horz %d\n", GetDesktopWindow(), screen, GetDeviceCaps(screen, HORZRES));
        ReleaseDC(NULL, screen);
        GetModuleFileNameW(NULL, path, MAX_PATH);
        wsprintfW(command, L"\"%s\" child", path);
        if (!CreateProcessW(path, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process))
        {
            wprintf(L"parent: CreateProcess failed %lu\n", GetLastError());
            return 1;
        }
        WaitForSingleObject(process.hProcess, 600000);
        GetExitCodeProcess(process.hProcess, &code);
        wprintf(L"parent: child exited with %lu\n", code);
        {
            /* the child's report, written beside the program */
            FILE *report = _wfopen(L"gdi_child.txt", L"r, ccs=UTF-8");
            wchar_t line[1024];
            while (report && fgetws(line, ARRAYSIZE(line), report)) wprintf(L"child: %ls", line);
            if (report) fclose(report);
        }
        fflush(stdout);
        return 0;
    }
    NONCLIENTMETRICSW metrics = {.cbSize = sizeof(metrics)};
    BOOL got = SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(metrics), &metrics, 0);
    HDC screen = GetDC(NULL);
    LOGFONTW arial = {.lfHeight = -13, .lfWeight = FW_NORMAL, .lfFaceName = L"Arial"};

    wprintf(L"SPI_GETNONCLIENTMETRICS %d (size %u)\n", got, (unsigned)sizeof(metrics));
    wprintf(L"screen dc %p: horz %d vert %d bits %d logpixels %d/%d | metrics %dx%d virtual %d,%d %dx%d monitors %d\n",
            screen, GetDeviceCaps(screen, HORZRES), GetDeviceCaps(screen, VERTRES), GetDeviceCaps(screen, BITSPIXEL),
            GetDeviceCaps(screen, LOGPIXELSX), GetDeviceCaps(screen, LOGPIXELSY), GetSystemMetrics(SM_CXSCREEN),
            GetSystemMetrics(SM_CYSCREEN), GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN),
            GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN), GetSystemMetrics(SM_CMONITORS));
    ReleaseDC(NULL, screen);
    EnumDisplayMonitors(NULL, NULL, monitor, 0);
    for (int dib = 0; dib < 2; dib++)
    {
        measure(L"message font", &metrics.lfMessageFont, dib);
        measure(L"caption font", &metrics.lfCaptionFont, dib);
        measure(L"menu font", &metrics.lfMenuFont, dib);
        measure(L"status font", &metrics.lfStatusFont, dib);
        measure(L"Arial 13", &arial, dib);
    }
    /* As a per-monitor DPI aware program (Chromium) sees the same */
    {
        BOOL set = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        HMONITOR primary = MonitorFromPoint((POINT){0, 0}, MONITOR_DEFAULTTOPRIMARY);
        UINT dpi_x = 0, dpi_y = 0;
        HRESULT hr = GetDpiForMonitor(primary, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y);
        NONCLIENTMETRICSW for_dpi = {.cbSize = sizeof(for_dpi)};
        BOOL got_for_dpi = SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS, sizeof(for_dpi), &for_dpi, 0, dpi_x ? dpi_x : 96);
        wprintf(L"per-monitor v2: set %d system dpi %u window dpi %u monitor %p dpi hr %lx %ux%u | for dpi %d message \"%ls\" %ld"
                L" | cx %d cy %d caption %d\n",
                set, GetDpiForSystem(), GetDpiForWindow(GetDesktopWindow()), primary, hr, dpi_x, dpi_y, got_for_dpi,
                for_dpi.lfMessageFont.lfFaceName, for_dpi.lfMessageFont.lfHeight,
                GetSystemMetricsForDpi(SM_CXSCREEN, dpi_x ? dpi_x : 96), GetSystemMetricsForDpi(SM_CYSCREEN, dpi_x ? dpi_x : 96),
                GetSystemMetricsForDpi(SM_CYCAPTION, dpi_x ? dpi_x : 96));
        measure(L"dpi message font", &for_dpi.lfMessageFont, FALSE);
        screen = GetDC(NULL);
        wprintf(L"screen dc after: logpixels %d/%d horz %d\n", GetDeviceCaps(screen, LOGPIXELSX), GetDeviceCaps(screen, LOGPIXELSY),
                GetDeviceCaps(screen, HORZRES));
        ReleaseDC(NULL, screen);
    }
    wprintf(L"done\n");
    fflush(stdout);
    return argc > 1 ? 42 : 0;
}
