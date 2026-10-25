/* Our own probe: the loopback TCP connections and the processes that own them,
 * as GetExtendedTcpTable(TCP_TABLE_OWNER_PID_ALL) reports them. Programs use
 * this to check who connected to a local server; with several Windows
 * processes in one host process (docs/MULTIPROCESS.md) Wine must still name
 * the right Windows process. It opens a loopback connection of its own and checks
 * that its own process is named as the owner (32-bit and 64-bit builds alike).
 *
 *   x86_64-w64-mingw32-clang -O2 -municode tcp_owner_probe.c -o tcp_owner_probe.exe -liphlpapi -lws2_32
 *   i686-w64-mingw32-clang -O2 -municode tcp_owner_probe.c -o tcp_owner_probe32.exe -liphlpapi -lws2_32
 */
#include <winsock2.h>
#include <windows.h>
#include <iphlpapi.h>
#include <stdio.h>
#include <stdlib.h>

static void image_name(DWORD pid, WCHAR *name, DWORD size)
{
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    name[0] = 0;
    if (!process) { lstrcpynW(name, L"(cannot open)", size); return; }
    if (!QueryFullProcessImageNameW(process, 0, name, &size)) lstrcpynW(name, L"(no name)", size);
    CloseHandle(process);
}

int wmain(void)
{
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP), client = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    struct sockaddr_in address = { .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    int length = sizeof(address);
    bind(listener, (struct sockaddr *)&address, sizeof(address));
    getsockname(listener, (struct sockaddr *)&address, &length);
    listen(listener, 1);
    connect(client, (struct sockaddr *)&address, sizeof(address));
    SOCKET server = accept(listener, NULL, NULL);
    u_short port = address.sin_port;
    int own = 0;
    (void)server;

    DWORD size = 0;
    GetExtendedTcpTable(NULL, &size, FALSE, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0);
    MIB_TCPTABLE_OWNER_PID *table = malloc(size);
    DWORD result = GetExtendedTcpTable(table, &size, FALSE, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0);
    if (result) { printf("GetExtendedTcpTable failed: %lu\n", result); return 1; }
    printf("%lu IPv4 connections\n", table->dwNumEntries);
    for (DWORD i = 0; i < table->dwNumEntries; i++)
    {
        MIB_TCPROW_OWNER_PID *row = &table->table[i];
        if (row->dwLocalAddr != htonl(INADDR_LOOPBACK)) continue;
        WCHAR name[MAX_PATH];
        image_name(row->dwOwningPid, name, MAX_PATH);
        printf("127.0.0.1:%u -> port %u state %lu pid %04lx %ls\n", ntohs((u_short)row->dwLocalPort),
               ntohs((u_short)row->dwRemotePort), row->dwState, row->dwOwningPid, name);
        if (((u_short)row->dwLocalPort == port || (u_short)row->dwRemotePort == port) &&
            row->dwOwningPid == GetCurrentProcessId()) own++;
    }
    printf("own connection rows naming this process (%04lx): %d\n", GetCurrentProcessId(), own);
    printf("%s\n", own >= 2 ? "PASS" : "FAIL");
    return own >= 2 ? 0 : 1;
}
