#include <arpa/inet.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <netdb.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#ifndef IDV_DNS_TARGET_SUFFIX
#define IDV_DNS_TARGET_SUFFIX "ws2_32.so"
#endif

typedef int (*getaddrinfo_fn)(const char *, const char *, const struct addrinfo *, struct addrinfo **);
typedef struct hostent *(*gethostbyname_fn)(const char *);

static getaddrinfo_fn original_getaddrinfo;
static gethostbyname_fn original_gethostbyname;
static int mapped_marker;

#define MARK(message) (void)write(STDERR_FILENO, (message), sizeof(message) - 1)

static int equal_dns_name(const char *candidate, const char *expected)
{
    size_t candidate_length;
    size_t expected_length;

    if (!candidate || !expected) return 0;
    candidate_length = strlen(candidate);
    while (candidate_length && candidate[candidate_length - 1] == '.') --candidate_length;
    expected_length = strlen(expected);
    return candidate_length == expected_length && strncasecmp(candidate, expected, expected_length) == 0;
}

static int is_managed_login_domain(const char *node)
{
    return equal_dns_name(node, "service.mkey.163.com") ||
           equal_dns_name(node, "sdk-os.mpsdk.easebar.com") ||
           equal_dns_name(node, "mgbsdk.matrix.netease.com");
}

static void mark_mapping_once(void)
{
    if (__atomic_exchange_n(&mapped_marker, 1, __ATOMIC_RELAXED) == 0)
        MARK("IdentityV login DNS: mapped managed domain to local proxy\n");
}

int idv_login_getaddrinfo(const char *node, const char *service, const struct addrinfo *hints,
                          struct addrinfo **result)
{
    getaddrinfo_fn original = __atomic_load_n(&original_getaddrinfo, __ATOMIC_ACQUIRE);
    if (!original) return EAI_FAIL;
    if (!is_managed_login_domain(node)) return original(node, service, hints, result);
    mark_mapping_once();
    return original("127.0.0.1", service, hints, result);
}

struct hostent *idv_login_gethostbyname(const char *node)
{
    gethostbyname_fn original = __atomic_load_n(&original_gethostbyname, __ATOMIC_ACQUIRE);
    if (!original) {
        h_errno = NO_RECOVERY;
        return NULL;
    }
    if (!is_managed_login_domain(node)) return original(node);
    mark_mapping_once();
    return original("127.0.0.1");
}

static int path_has_target_suffix(const char *path)
{
    static const char suffix[] = IDV_DNS_TARGET_SUFFIX;
    const char *name = path;
    const char *cursor = path;
    size_t index;

    if (!path) return 0;
    while (*cursor) {
        if (*cursor == '/') name = cursor + 1;
        ++cursor;
    }
    for (index = 0; suffix[index]; ++index) {
        if (name[index] != suffix[index]) return 0;
    }
    return name[index] == '\0';
}

static void rebind_section(const struct section_64 *section, intptr_t slide,
                           const struct nlist_64 *symbols, const char *strings,
                           const uint32_t *indirect_symbols, int *addrinfo_bound,
                           int *hostbyname_bound)
{
    void **slots;
    uint32_t count;
    uint32_t index;

    if (!section->size) return;
    slots = (void **)(slide + section->addr);
    count = (uint32_t)(section->size / sizeof(void *));
    for (index = 0; index < count; ++index) {
        uint32_t symbol_index = indirect_symbols[section->reserved1 + index];
        const char *symbol_name;
        if (symbol_index == INDIRECT_SYMBOL_ABS || symbol_index == INDIRECT_SYMBOL_LOCAL ||
            symbol_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
        symbol_name = strings + symbols[symbol_index].n_un.n_strx;
        if (*symbol_name == '_') ++symbol_name;
        if (!*addrinfo_bound && strcmp(symbol_name, "getaddrinfo") == 0) {
            slots[index] = (void *)idv_login_getaddrinfo;
            *addrinfo_bound = 1;
            MARK("IdentityV login DNS: bound getaddrinfo\n");
        } else if (!*hostbyname_bound && strcmp(symbol_name, "gethostbyname") == 0) {
            slots[index] = (void *)idv_login_gethostbyname;
            *hostbyname_bound = 1;
            MARK("IdentityV login DNS: bound gethostbyname\n");
        }
    }
}

static void inspect_image(const struct mach_header *header, intptr_t slide)
{
    const struct mach_header_64 *mach_header = (const struct mach_header_64 *)header;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct segment_command_64 *linkedit = NULL;
    const struct load_command *command;
    const struct nlist_64 *symbols;
    const uint32_t *indirect;
    const char *strings;
    intptr_t linkedit_base;
    int addrinfo_bound = 0;
    int hostbyname_bound = 0;
    uint32_t index;

    if (mach_header->magic != MH_MAGIC_64) return;
    command = (const struct load_command *)(mach_header + 1);
    for (index = 0; index < mach_header->ncmds; ++index) {
        if (command->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)command;
        if (command->cmd == LC_DYSYMTAB) dysymtab = (const struct dysymtab_command *)command;
        if (command->cmd == LC_SEGMENT_64 &&
            strcmp(((const struct segment_command_64 *)command)->segname, "__LINKEDIT") == 0)
            linkedit = (const struct segment_command_64 *)command;
        command = (const struct load_command *)((const char *)command + command->cmdsize);
    }
    if (!symtab || !dysymtab || !linkedit) {
        MARK("IdentityV login DNS: target symbol tables unavailable\n");
        return;
    }

    linkedit_base = slide + linkedit->vmaddr - linkedit->fileoff;
    symbols = (const struct nlist_64 *)(linkedit_base + symtab->symoff);
    strings = (const char *)(linkedit_base + symtab->stroff);
    indirect = (const uint32_t *)(linkedit_base + dysymtab->indirectsymoff);
    command = (const struct load_command *)(mach_header + 1);
    for (index = 0; index < mach_header->ncmds; ++index) {
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            const struct section_64 *section = (const struct section_64 *)(segment + 1);
            uint32_t section_index;
            for (section_index = 0; section_index < segment->nsects; ++section_index) {
                if ((strcmp(section[section_index].sectname, "__la_symbol_ptr") == 0 ||
                     strcmp(section[section_index].sectname, "__nl_symbol_ptr") == 0) &&
                    strcmp(section[section_index].segname, "__DATA") == 0)
                    rebind_section(&section[section_index], slide, symbols, strings, indirect,
                                   &addrinfo_bound, &hostbyname_bound);
            }
        }
        command = (const struct load_command *)((const char *)command + command->cmdsize);
    }
    if (addrinfo_bound && hostbyname_bound) MARK("IdentityV login DNS: target imports ready\n");
    else MARK("IdentityV login DNS: target imports incomplete\n");
}

static void image_added(const struct mach_header *header, intptr_t slide)
{
    uint32_t count = _dyld_image_count();
    uint32_t index;
    for (index = 0; index < count; ++index) {
        if (_dyld_get_image_header(index) == header && path_has_target_suffix(_dyld_get_image_name(index))) {
            inspect_image(header, slide);
            return;
        }
    }
}

__attribute__((constructor)) static void dns_rebinder_loaded(void)
{
    getaddrinfo_fn direct_getaddrinfo = getaddrinfo;
    gethostbyname_fn direct_gethostbyname = gethostbyname;

    MARK("IdentityV login DNS: rebinder loaded\n");
    if (!direct_getaddrinfo || !direct_gethostbyname ||
        direct_getaddrinfo == idv_login_getaddrinfo ||
        direct_gethostbyname == idv_login_gethostbyname) {
        MARK("IdentityV login DNS: direct originals unavailable\n");
        return;
    }
    __atomic_store_n(&original_getaddrinfo, direct_getaddrinfo, __ATOMIC_RELEASE);
    __atomic_store_n(&original_gethostbyname, direct_gethostbyname, __ATOMIC_RELEASE);
    _dyld_register_func_for_add_image(image_added);
}
