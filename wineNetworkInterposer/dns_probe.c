#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef const char *(*lookup_fn)(const char *);

int main(int argc, char **argv)
{
    void *fixture;
    lookup_fn lookup_addrinfo;
    lookup_fn lookup_hostbyname;
    char managed_addrinfo[64];
    char managed_hostbyname[64];
    char unmanaged_addrinfo[64];
    const char *value;

    if (argc != 2) return 64;
    fixture = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!fixture) return 1;
    lookup_addrinfo = (lookup_fn)dlsym(fixture, "fixture_getaddrinfo");
    lookup_hostbyname = (lookup_fn)dlsym(fixture, "fixture_gethostbyname");
    if (!lookup_addrinfo || !lookup_hostbyname) return 1;

    value = lookup_addrinfo("service.mkey.163.com");
    if (!value) return 1;
    strlcpy(managed_addrinfo, value, sizeof(managed_addrinfo));
    value = lookup_hostbyname("service.mkey.163.com.");
    if (!value) return 1;
    strlcpy(managed_hostbyname, value, sizeof(managed_hostbyname));
    value = lookup_addrinfo("example.com");
    if (!value) return 1;
    strlcpy(unmanaged_addrinfo, value, sizeof(unmanaged_addrinfo));
    printf("managed_getaddrinfo=%s\n", managed_addrinfo);
    printf("managed_gethostbyname=%s\n", managed_hostbyname);
    printf("unmanaged_getaddrinfo=%s\n", unmanaged_addrinfo);
    return 0;
}
