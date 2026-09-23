#include <arpa/inet.h>
#include <netdb.h>
#include <stddef.h>

const char *fixture_getaddrinfo(const char *name)
{
    static char address[INET_ADDRSTRLEN];
    struct addrinfo hints = {0};
    struct addrinfo *result = NULL;
    const void *bytes;

    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(name, "443", &hints, &result) || !result) return NULL;
    bytes = &((const struct sockaddr_in *)result->ai_addr)->sin_addr;
    if (!inet_ntop(AF_INET, bytes, address, sizeof(address))) {
        freeaddrinfo(result);
        return NULL;
    }
    freeaddrinfo(result);
    return address;
}

const char *fixture_gethostbyname(const char *name)
{
    static char address[INET_ADDRSTRLEN];
    struct hostent *host = gethostbyname(name);
    if (!host || host->h_addrtype != AF_INET || host->h_length != 4 || !host->h_addr_list[0]) return NULL;
    if (!inet_ntop(AF_INET, host->h_addr_list[0], address, sizeof(address))) return NULL;
    return address;
}
