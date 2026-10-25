/* Our own probe: overlapped I/O as a 32-bit program uses it, through a named pipe,
 * an I/O completion port and a loopback socket. With WoW64's 32-bit address space at
 * a host window (docs/WINDOWS.md) every completion must reach the program's own
 * OVERLAPPED and buffers.
 *
 *   i686-w64-mingw32-clang -O2 overlapped_probe.c -o overlapped_probe.exe -lws2_32
 */
#include <winsock2.h>
#include <windows.h>
#include <stdio.h>
#include <string.h>

static int failures;

static void check(const char *what, BOOL ok)
{
    printf("%-40s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok) failures++;
}

static void pipe_test(void)
{
    const char *name = "\\\\.\\pipe\\tolkara_overlapped_probe";
    HANDLE server = CreateNamedPipeA(name, PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
                                     PIPE_TYPE_BYTE | PIPE_WAIT, 1, 4096, 4096, 0, NULL);
    HANDLE client = CreateFileA(name, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING,
                                FILE_FLAG_OVERLAPPED, NULL);
    check("pipe: create", server != INVALID_HANDLE_VALUE && client != INVALID_HANDLE_VALUE);

    char buffer[64] = {0};
    OVERLAPPED read = {0}, write = {0};
    read.hEvent = CreateEventA(NULL, TRUE, FALSE, NULL);
    write.hEvent = CreateEventA(NULL, TRUE, FALSE, NULL);
    BOOL started = ReadFile(server, buffer, sizeof(buffer), NULL, &read) || GetLastError() == ERROR_IO_PENDING;
    check("pipe: overlapped read pending", started);
    DWORD written = 0, got = 0;
    WriteFile(client, "hello", 5, NULL, &write);
    GetOverlappedResult(client, &write, &written, TRUE);
    DWORD wait = WaitForSingleObject(read.hEvent, 3000);
    check("pipe: read completes", wait == WAIT_OBJECT_0);
    check("pipe: result", GetOverlappedResult(server, &read, &got, FALSE) && got == 5 && !memcmp(buffer, "hello", 5));

    /* the same pipe through a completion port */
    HANDLE port = CreateIoCompletionPort(server, NULL, 42, 0);
    memset(&read, 0, sizeof(read));
    memset(buffer, 0, sizeof(buffer));
    ReadFile(server, buffer, sizeof(buffer), NULL, &read);
    WriteFile(client, "again", 5, NULL, &write);
    GetOverlappedResult(client, &write, &written, TRUE);
    ULONG_PTR key = 0;
    OVERLAPPED *done = NULL;
    BOOL ok = GetQueuedCompletionStatus(port, &got, &key, &done, 3000);
    check("port: completion arrives", ok);
    check("port: key, OVERLAPPED and data", ok && key == 42 && done == &read && got == 5 && !memcmp(buffer, "again", 5));
    CloseHandle(client);
    CloseHandle(server);
    CloseHandle(port);
}

static void socket_test(void)
{
    WSADATA data;
    WSAStartup(MAKEWORD(2, 2), &data);
    SOCKET listener = WSASocketW(AF_INET, SOCK_STREAM, IPPROTO_TCP, NULL, 0, WSA_FLAG_OVERLAPPED);
    struct sockaddr_in address = { .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    int length = sizeof(address);
    bind(listener, (struct sockaddr *)&address, sizeof(address));
    getsockname(listener, (struct sockaddr *)&address, &length);
    listen(listener, 1);
    SOCKET client = WSASocketW(AF_INET, SOCK_STREAM, IPPROTO_TCP, NULL, 0, WSA_FLAG_OVERLAPPED);
    check("socket: connect", !connect(client, (struct sockaddr *)&address, sizeof(address)));
    SOCKET server = accept(listener, NULL, NULL);
    check("socket: accept", server != INVALID_SOCKET);

    char buffer[64] = {0};
    WSABUF wsabuf = { sizeof(buffer), buffer };
    DWORD flags = 0, got = 0;
    WSAOVERLAPPED overlapped = {0};
    overlapped.hEvent = WSACreateEvent();
    int result = WSARecv(server, &wsabuf, 1, NULL, &flags, &overlapped, NULL);
    check("socket: overlapped receive pending", !result || WSAGetLastError() == WSA_IO_PENDING);
    send(client, "socket", 6, 0);
    DWORD wait = WSAWaitForMultipleEvents(1, &overlapped.hEvent, TRUE, 3000, FALSE);
    check("socket: receive completes", wait == WSA_WAIT_EVENT_0);
    check("socket: result", WSAGetOverlappedResult(server, &overlapped, &got, FALSE, &flags) && got == 6 &&
                            !memcmp(buffer, "socket", 6));
    closesocket(client);
    closesocket(server);
    closesocket(listener);
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    pipe_test();
    socket_test();
    printf("%s\n", failures ? "FAIL" : "PASS");
    return failures ? 1 : 0;
}
