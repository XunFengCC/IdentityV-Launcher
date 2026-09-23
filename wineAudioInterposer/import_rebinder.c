#include <CoreAudio/CoreAudio.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#if defined(IDV_REBINDER_FILTER) || defined(IDV_REBINDER_ALIAS)
#include <pthread.h>
#include <stdlib.h>
#include "rebinder_filter_protocol.h"
#ifdef IDV_REBINDER_ALIAS
#include "rebinder_alias_translate.h"
#endif
#endif
#include <unistd.h>

typedef OSStatus (*get_data_fn)(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *, void *);
typedef OSStatus (*get_size_fn)(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);

static get_data_fn original_get_data;
static get_size_fn original_get_size;
static int entered_marker;
#if defined(IDV_REBINDER_FILTER) || defined(IDV_REBINDER_ALIAS)
static pthread_key_t filter_key;
static int filter_key_ready;
static int narrowed_marker;
#ifdef IDV_REBINDER_ALIAS
static const CFStringRef alias_uid = CFSTR("com.xunfeng.identityv.system-default-input.v1");
static const CFStringRef alias_name = CFSTR("System Default Microphone");
#endif
static void destroy_filter_state(void *value) { free(value); }
static idv_rebinder_filter_state_t *filter_state(void)
{
    if (!filter_key_ready) return NULL;
    idv_rebinder_filter_state_t *state = pthread_getspecific(filter_key);
    if (!state) {
        state = calloc(1, sizeof(*state));
        if (state && pthread_setspecific(filter_key, state) != 0) { free(state); return NULL; }
    }
    return state;
}
#endif

#define MARK(message) (void)write(STDERR_FILENO, (message), sizeof(message) - 1)

static int ends_with_winecoreaudio(const char *path)
{
    static const char suffix[] = "winecoreaudio.so";
    const char *tail = path;
    const char *cursor = path;
    if (!path) return 0;
    while (*cursor) { if (*cursor == '/') tail = cursor + 1; ++cursor; }
    for (unsigned int i = 0; suffix[i]; ++i) if (tail[i] != suffix[i]) return 0;
    return tail[sizeof(suffix) - 1] == '\0';
}

OSStatus idv_rebound_AudioObjectGetPropertyData(AudioObjectID object, const AudioObjectPropertyAddress *address, UInt32 qualifier_size, const void *qualifier, UInt32 *data_size, void *out_data)
{
    if (__atomic_exchange_n(&entered_marker, 1, __ATOMIC_RELAXED) == 0) MARK("IdentityV CoreAudio: rebinder replacement entered\n");
    get_data_fn original = __atomic_load_n(&original_get_data, __ATOMIC_ACQUIRE);
    if (!original) return kAudioHardwareUnspecifiedError;
#if defined(IDV_REBINDER_FILTER) || defined(IDV_REBINDER_ALIAS)
    idv_rebinder_filter_state_t *state = filter_state();
    int exact = object == kAudioObjectSystemObject && address && address->mScope == kAudioObjectPropertyScopeGlobal && address->mElement == kAudioObjectPropertyElementMain && qualifier_size == 0 && !qualifier;
#ifdef IDV_REBINDER_ALIAS
    int alias_meta = object != kAudioObjectSystemObject && address && state && object == state->device && address->mScope == kAudioDevicePropertyScopeInput && address->mElement == 0 && qualifier_size == 0 && !qualifier;
    int alias_translate = idv_alias_translate_matches(object, address, qualifier_size, qualifier, data_size, out_data);
    if (alias_translate) { OSStatus status = idv_alias_translate(state, original, data_size, out_data); if (status == noErr) MARK("IdentityV CoreAudio: alias translated\n"); return status; }
    if (!state || (!exact && !alias_meta)) { if (state) idv_reset(state); return original(object, address, qualifier_size, qualifier, data_size, out_data); }
#else
    if (!state || !exact) { if (state) idv_reset(state); return original(object, address, qualifier_size, qualifier, data_size, out_data); }
#endif
    uint32_t selector = address->mSelector;
    if (selector == kAudioHardwarePropertyDefaultInputDevice) {
        OSStatus result = original(object, address, qualifier_size, qualifier, data_size, out_data);
        if (result == noErr && data_size && out_data && *data_size == sizeof(AudioDeviceID) && idv_note_default(state, *(AudioDeviceID *)out_data, kAudioObjectUnknown)) MARK("IdentityV CoreAudio: rebinder-filter protocol default observed\n");
        else { idv_note_default_failure(state); MARK("IdentityV CoreAudio: rebinder-filter protocol default failed\n"); }
        return result;
    }
#ifdef IDV_REBINDER_ALIAS
    if (alias_meta && selector == kAudioDevicePropertyStreamConfiguration && data_size && out_data && *data_size) {
        if (state->state == IDV_EXPECT_STREAM_SIZE) { idv_reset(state); return original(object,address,qualifier_size,qualifier,data_size,out_data); }
        if (state->state == IDV_EXPECT_STREAM_DATA) { OSStatus result=original(object,address,qualifier_size,qualifier,data_size,out_data); if(result==noErr) (void)idv_alias_accept(state,object,IDV_ALIAS_STREAM_DATA); else idv_reset(state); return result; }
    }
    if (alias_meta && state->state == IDV_EXPECT_NAME && selector == kAudioObjectPropertyName && data_size && out_data && *data_size == sizeof(CFStringRef)) {
        *(CFStringRef *)out_data = CFStringCreateCopy(NULL, alias_name);
        if (!*(CFStringRef *)out_data) { idv_reset(state); return kAudioHardwareUnspecifiedError; }
        MARK("IdentityV CoreAudio: alias name substituted\n"); (void)idv_alias_accept(state,object,IDV_ALIAS_NAME); return noErr;
    }
    if (alias_meta && state->state == IDV_EXPECT_UID && selector == kAudioDevicePropertyDeviceUID && data_size && out_data && *data_size == sizeof(CFStringRef)) { *(CFStringRef *)out_data=CFStringCreateCopy(NULL,alias_uid); if(!*(CFStringRef *)out_data){idv_reset(state);return kAudioHardwareUnspecifiedError;} MARK("IdentityV CoreAudio: alias UID substituted\n"); (void)idv_alias_accept(state,object,IDV_ALIAS_UID); return noErr; }
    if (alias_meta) { idv_reset(state); return original(object,address,qualifier_size,qualifier,data_size,out_data); }
#endif
    if (selector != kAudioHardwarePropertyDevices || !data_size || !out_data || *data_size < sizeof(AudioDeviceID)) { idv_reset(state); return original(object, address, qualifier_size, qualifier, data_size, out_data); }
    uint32_t device;
#ifdef IDV_REBINDER_ALIAS
    if (!idv_take_alias_data(state, &device))
#else
    if (!idv_take_data(state, &device))
#endif
        return original(object, address, qualifier_size, qualifier, data_size, out_data);
    {
        *(AudioDeviceID *)out_data = (AudioDeviceID)device; *data_size = sizeof(AudioDeviceID);
        if (__atomic_exchange_n(&narrowed_marker, 1, __ATOMIC_RELAXED) == 0) MARK("IdentityV CoreAudio: rebinder-filter narrowed devices\n");
        return noErr;
    }
#else
    return original(object, address, qualifier_size, qualifier, data_size, out_data);
#endif
}

OSStatus idv_rebound_AudioObjectGetPropertyDataSize(AudioObjectID object, const AudioObjectPropertyAddress *address, UInt32 qualifier_size, const void *qualifier, UInt32 *out_size)
{
    if (__atomic_exchange_n(&entered_marker, 1, __ATOMIC_RELAXED) == 0) MARK("IdentityV CoreAudio: rebinder replacement entered\n");
    get_size_fn original = __atomic_load_n(&original_get_size, __ATOMIC_ACQUIRE);
    if (!original) return kAudioHardwareUnspecifiedError;
#if defined(IDV_REBINDER_FILTER) || defined(IDV_REBINDER_ALIAS)
    idv_rebinder_filter_state_t *state = filter_state();
#ifdef IDV_REBINDER_ALIAS
    if (state && object == state->device && address && address->mSelector == kAudioDevicePropertyStreamConfiguration && address->mScope == kAudioDevicePropertyScopeInput && address->mElement == 0 && qualifier_size == 0 && !qualifier && out_size && state->state == IDV_EXPECT_STREAM_SIZE) { OSStatus r=original(object,address,qualifier_size,qualifier,out_size); if(r==noErr)(void)idv_alias_accept(state,object,IDV_ALIAS_STREAM_SIZE); else idv_reset(state); return r; }
#endif
    int exact = object == kAudioObjectSystemObject && address && address->mScope == kAudioObjectPropertyScopeGlobal && address->mElement == kAudioObjectPropertyElementMain && qualifier_size == 0 && !qualifier;
    if (!state || !exact || address->mSelector != kAudioHardwarePropertyDevices || !out_size) { if (state) idv_reset(state); return original(object, address, qualifier_size, qualifier, out_size); }
    if (state->state == IDV_EXPECT_SIZE_FAIL) { idv_reset(state); MARK("IdentityV CoreAudio: rebinder-filter protocol size fail-closed\n"); return kAudioHardwareUnspecifiedError; }
    if (!idv_note_size(state))
        return original(object, address, qualifier_size, qualifier, out_size);
    *out_size = sizeof(AudioDeviceID); MARK("IdentityV CoreAudio: rebinder-filter protocol size narrowed\n"); return noErr;
#else
    return original(object, address, qualifier_size, qualifier, out_size);
#endif
}

static void rebind_section(const struct section_64 *section, intptr_t slide, const struct nlist_64 *symbols,
                           const char *strings, const uint32_t *indirect_symbols, int *data_bound, int *size_bound)
{
    if (section->size == 0) return;
    void **slots = (void **)(slide + section->addr);
    uint32_t count = (uint32_t)(section->size / sizeof(void *));
    for (uint32_t index = 0; index < count; ++index) {
        uint32_t symbol_index = indirect_symbols[section->reserved1 + index];
        if (symbol_index == INDIRECT_SYMBOL_ABS || symbol_index == INDIRECT_SYMBOL_LOCAL || symbol_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
        const char *symbol_name = strings + symbols[symbol_index].n_un.n_strx;
        if (symbol_name[0] == '_') ++symbol_name;
        if (!*data_bound && __builtin_strcmp(symbol_name, "AudioObjectGetPropertyData") == 0) {
            slots[index] = (void *)idv_rebound_AudioObjectGetPropertyData;
            *data_bound = 1;
            MARK("IdentityV CoreAudio: rebinder bound data\n");
        } else if (!*size_bound && __builtin_strcmp(symbol_name, "AudioObjectGetPropertyDataSize") == 0) {
            slots[index] = (void *)idv_rebound_AudioObjectGetPropertyDataSize;
            *size_bound = 1;
            MARK("IdentityV CoreAudio: rebinder bound size\n");
        }
    }
}

static void inspect_image(const struct mach_header *header, intptr_t slide)
{
    const struct mach_header_64 *mh = (const struct mach_header_64 *)header;
    if (mh->magic != MH_MAGIC_64) { MARK("IdentityV CoreAudio: rebinder unsupported image\n"); return; }
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct segment_command_64 *linkedit = NULL;
    const struct load_command *command = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; ++i) {
        if (command->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)command;
        if (command->cmd == LC_DYSYMTAB) dysymtab = (const struct dysymtab_command *)command;
        if (command->cmd == LC_SEGMENT_64 && __builtin_strcmp(((const struct segment_command_64 *)command)->segname, "__LINKEDIT") == 0)
            linkedit = (const struct segment_command_64 *)command;
        command = (const struct load_command *)((const char *)command + command->cmdsize);
    }
    if (!symtab || !dysymtab || !linkedit) { MARK("IdentityV CoreAudio: rebinder symbol tables missing\n"); return; }
    intptr_t linkedit_base = slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symbols = (const struct nlist_64 *)(linkedit_base + symtab->symoff);
    const char *strings = (const char *)(linkedit_base + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(linkedit_base + dysymtab->indirectsymoff);
    int data_bound = 0, size_bound = 0;
    command = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; ++i) {
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            const struct section_64 *section = (const struct section_64 *)(segment + 1);
            for (uint32_t j = 0; j < segment->nsects; ++j) {
                if ((__builtin_strcmp(section[j].sectname, "__la_symbol_ptr") == 0 || __builtin_strcmp(section[j].sectname, "__nl_symbol_ptr") == 0) &&
                    __builtin_strcmp(section[j].segname, "__DATA") == 0)
                    rebind_section(&section[j], slide, symbols, strings, indirect, &data_bound, &size_bound);
            }
        }
        command = (const struct load_command *)((const char *)command + command->cmdsize);
    }
    if (data_bound && size_bound) MARK("IdentityV CoreAudio: rebinder complete\n");
    else MARK("IdentityV CoreAudio: rebinder target imports incomplete\n");
}

static void image_added(const struct mach_header *header, intptr_t slide)
{
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; ++i) {
        if (_dyld_get_image_header(i) == header && ends_with_winecoreaudio(_dyld_get_image_name(i))) {
            if (!__atomic_load_n(&original_get_data, __ATOMIC_ACQUIRE) || !__atomic_load_n(&original_get_size, __ATOMIC_ACQUIRE)) {
                MARK("IdentityV CoreAudio: rebinder originals unavailable\n");
                return;
            }
            MARK("IdentityV CoreAudio: rebinder winecoreaudio found\n");
            inspect_image(header, slide);
            return;
        }
    }
}

__attribute__((constructor)) static void rebinder_loaded(void)
{
#if defined(IDV_REBINDER_FILTER) || defined(IDV_REBINDER_ALIAS)
    MARK("IdentityV CoreAudio: rebinder-filter loaded\n");
    if (pthread_key_create(&filter_key, destroy_filter_state) != 0) { MARK("IdentityV CoreAudio: rebinder-filter key failed\n"); return; }
    filter_key_ready = 1;
#else
    MARK("IdentityV CoreAudio: rebinder loaded\n");
#endif
    /* These are this dylib's own direct CoreAudio imports, never Wine's lazy slots. */
    get_data_fn direct_data = AudioObjectGetPropertyData;
    get_size_fn direct_size = AudioObjectGetPropertyDataSize;
    if (!direct_data || !direct_size || direct_data == idv_rebound_AudioObjectGetPropertyData || direct_size == idv_rebound_AudioObjectGetPropertyDataSize) {
        MARK("IdentityV CoreAudio: rebinder direct originals unavailable\n");
        return;
    }
    __atomic_store_n(&original_get_data, direct_data, __ATOMIC_RELEASE);
    __atomic_store_n(&original_get_size, direct_size, __ATOMIC_RELEASE);
    MARK("IdentityV CoreAudio: rebinder direct originals ready\n");
#if defined(IDV_REBINDER_FILTER) || defined(IDV_REBINDER_ALIAS)
    MARK("IdentityV CoreAudio: rebinder-filter ready\n");
#endif
    _dyld_register_func_for_add_image(image_added);
}
