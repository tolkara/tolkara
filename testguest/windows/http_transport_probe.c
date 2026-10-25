/* Owned transport check against the public Steam update manifest. No credentials. */
#define _WIN32_WINNT 0x0601
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <winhttp.h>
#include <stdio.h>
#include <string.h>

static int http(BOOL secure)
{
    HINTERNET session=WinHttpOpen(L"Tolkara transport probe",WINHTTP_ACCESS_TYPE_NO_PROXY,NULL,NULL,0);
    HINTERNET connection=NULL, request=NULL;
    DWORD status=0, size=sizeof(status), received=0, error=0;
    char buffer[64];
    if (!session) { printf("HTTP open error=%lu\n",GetLastError()); return 1; }
    WinHttpSetTimeouts(session,8000,8000,8000,8000);
    connection=WinHttpConnect(session,L"client-update.steamstatic.com",secure ? 443 : 80,0);
    if (connection) request=WinHttpOpenRequest(connection,L"GET",L"/steam_client_win64",NULL,NULL,NULL,secure ? WINHTTP_FLAG_SECURE : 0);
    if (!request || !WinHttpSendRequest(request,NULL,0,NULL,0,0,0) || !WinHttpReceiveResponse(request,NULL) ||
        !WinHttpQueryHeaders(request,WINHTTP_QUERY_STATUS_CODE|WINHTTP_QUERY_FLAG_NUMBER,NULL,&status,&size,NULL) ||
        !WinHttpReadData(request,buffer,sizeof(buffer),&received)) error=GetLastError();
    printf("HTTP secure=%d error=%lu status=%lu bytes=%lu\n",secure,error,status,received);
    if(request) WinHttpCloseHandle(request);
    if(connection) WinHttpCloseHandle(connection);
    WinHttpCloseHandle(session);
    return error || !status || !received;
}

int main(void)
{
    WSADATA wsa; struct addrinfo hints={0}, *addresses=NULL;
    int error=WSAStartup(MAKEWORD(2,2),&wsa), failures=0;
    printf("NET WSAStartup=%d\n",error);
    if(error) return 1;
    hints.ai_family=AF_INET; hints.ai_socktype=SOCK_STREAM;
    error=getaddrinfo("client-update.steamstatic.com","80",&hints,&addresses);
    printf("NET resolve=%d\n",error);
    if(!error) {
        SOCKET sock=socket(addresses->ai_family,addresses->ai_socktype,addresses->ai_protocol);
        u_long nonblocking=1; int result=ioctlsocket(sock,FIONBIO,&nonblocking);
        printf("NET nonblocking=%d error=%d\n",result,result ? WSAGetLastError() : 0);
        if (result) failures++;
        result=connect(sock,addresses->ai_addr,(int)addresses->ai_addrlen);
        error=result ? WSAGetLastError() : 0;
        printf("NET connect=%d error=%d\n",result,error);
        if(result && error==WSAEWOULDBLOCK) {
            fd_set writes,exceptions; struct timeval timeout={8,0};
            FD_ZERO(&writes); FD_ZERO(&exceptions); FD_SET(sock,&writes); FD_SET(sock,&exceptions);
            result=select(0,NULL,&writes,&exceptions,&timeout);
            int size=sizeof(error); error=0;
            int got=getsockopt(sock,SOL_SOCKET,SO_ERROR,(char *)&error,&size);
            printf("NET select=%d socket_error=%d getsockopt=%d\n",result,error,got);
            if(result<=0 || error || got) failures++;
        } else if(result) failures++;
        closesocket(sock); freeaddrinfo(addresses);
    } else failures++;
    WSACleanup();
    failures+=http(FALSE); failures+=http(TRUE);
    printf("NET %s failures=%d\n",failures ? "FAIL" : "PASS",failures);
    fflush(stdout); return !!failures;
}
