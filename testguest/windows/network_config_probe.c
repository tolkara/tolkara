#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <windns.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    int require_dns = argc == 2 && !strcmp(argv[1], "--require-ipv4-dns");
    int failures = 0;
    if (argc > 1 && !require_dns) return 64;
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa)) return 1;
    unsigned families[] = {AF_UNSPEC, AF_INET, AF_INET6};
    /* Wine windns.h internal queries used by its GetAdaptersAddresses path. */
    DNS_CONFIG_TYPE queries[] = {(DNS_CONFIG_TYPE)4144, (DNS_CONFIG_TYPE)4145, (DNS_CONFIG_TYPE)4146};
    for (unsigned i = 0; i < 3; ++i) {
        unsigned char dns[65536];
        DWORD size = sizeof(dns);
        DWORD dns_status = DnsQueryConfig(queries[i], 0, NULL, NULL, dns, &size);
        printf("DNS config family=%u status=%lu\n", families[i], dns_status);
        if (require_dns && i < 2 && dns_status) ++failures;
        for (unsigned skip = 0; skip < 2; ++skip) {
            ULONG bytes = 0, flags = skip ? GAA_FLAG_SKIP_DNS_SERVER : 0;
            ULONG status = GetAdaptersAddresses(families[i], flags, NULL, NULL, &bytes);
            if (status == ERROR_BUFFER_OVERFLOW) {
                IP_ADAPTER_ADDRESSES *adapters = malloc(bytes);
                if (!adapters) return 2;
                status = GetAdaptersAddresses(families[i], flags, NULL, adapters, &bytes);
                free(adapters);
            }
            printf("Adapters family=%u skip_dns=%u status=%lu\n", families[i], skip, status);
            if (require_dns && i < 2 && status) ++failures;
        }
    }
    struct addrinfo *result = NULL;
    int status = getaddrinfo("store.steampowered.com", NULL, NULL, &result);
    printf("Steam host resolution status=%d\n", status);
    if (result) freeaddrinfo(result);
    WSACleanup();
    return status ? 3 : failures ? 4 : 0;
}
