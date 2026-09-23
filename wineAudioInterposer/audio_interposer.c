#include <CoreAudio/CoreAudio.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* Build this source five times; each output adds exactly one behavior layer. */
#ifndef IDV_AUDIO_STAGE
#error "IDV_AUDIO_STAGE must be supplied by buildAndVerify.command"
#endif
#define IDV_STAGE_LOAD_ONLY 1
#define IDV_STAGE_PASSTHROUGH 2
#define IDV_STAGE_CALLER 3
#define IDV_STAGE_FILTER 4
#define IDV_STAGE_PASSTHROUGH_HANDLE 5
#define IDV_WRITE_MARKER(message) (void)write(STDERR_FILENO, (message), sizeof(message) - 1)

#if IDV_AUDIO_STAGE == IDV_STAGE_LOAD_ONLY
__attribute__((constructor)) static void idv_audio_load_marker(void)
{
    IDV_WRITE_MARKER("IdentityV CoreAudio: load-only loaded\n");
}
#else
typedef OSStatus (*get_data_fn)(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *, void *);
typedef OSStatus (*get_size_fn)(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);
OSStatus idv_AudioObjectGetPropertyData(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *, void *);
OSStatus idv_AudioObjectGetPropertyDataSize(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);
static get_data_fn real_get_data;
static get_size_fn real_get_size;
#if IDV_AUDIO_STAGE != IDV_STAGE_PASSTHROUGH_HANDLE
static pthread_once_t real_symbols_once = PTHREAD_ONCE_INIT;
#endif
#if IDV_AUDIO_STAGE != IDV_STAGE_FILTER
static int first_replacement_marker;
static void marker_once(const char *message, size_t length)
{
    if (__atomic_exchange_n(&first_replacement_marker, 1, __ATOMIC_RELAXED) == 0)
        (void)write(STDERR_FILENO, message, length);
}
#endif
#if IDV_AUDIO_STAGE == IDV_STAGE_PASSTHROUGH
__attribute__((constructor)) static void idv_audio_stage_loaded(void) { IDV_WRITE_MARKER("IdentityV CoreAudio: passthrough loaded\n"); }
#elif IDV_AUDIO_STAGE == IDV_STAGE_CALLER
__attribute__((constructor)) static void idv_audio_stage_loaded(void) { IDV_WRITE_MARKER("IdentityV CoreAudio: caller loaded\n"); }
#elif IDV_AUDIO_STAGE == IDV_STAGE_PASSTHROUGH_HANDLE
static void *coreaudio_handle;
static void resolve_coreaudio_handle_symbols(void)
{
    const char *coreaudio_install_name = "/System/Library/Frameworks/CoreAudio.framework/Versions/A/CoreAudio";
    coreaudio_handle = dlopen(coreaudio_install_name, RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD | RTLD_FIRST);
    if (!coreaudio_handle) {
        IDV_WRITE_MARKER("IdentityV CoreAudio: handle no-load missed\n");
        coreaudio_handle = dlopen(coreaudio_install_name, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
        if (coreaudio_handle) IDV_WRITE_MARKER("IdentityV CoreAudio: handle open fallback succeeded\n");
        else IDV_WRITE_MARKER("IdentityV CoreAudio: handle open fallback failed\n");
    } else {
        IDV_WRITE_MARKER("IdentityV CoreAudio: handle no-load succeeded\n");
    }
    if (coreaudio_handle) {
        real_get_data = (get_data_fn)dlsym(coreaudio_handle, "AudioObjectGetPropertyData");
        real_get_size = (get_size_fn)dlsym(coreaudio_handle, "AudioObjectGetPropertyDataSize");
    }
    if (!real_get_data || !real_get_size ||
        real_get_data == (get_data_fn)idv_AudioObjectGetPropertyData ||
        real_get_size == (get_size_fn)idv_AudioObjectGetPropertyDataSize) {
        real_get_data = NULL;
        real_get_size = NULL;
        IDV_WRITE_MARKER("IdentityV CoreAudio: handle resolve failed\n");
    } else {
        IDV_WRITE_MARKER("IdentityV CoreAudio: passthrough-handle resolved\n");
    }
}
__attribute__((constructor)) static void idv_audio_stage_loaded(void)
{
    IDV_WRITE_MARKER("IdentityV CoreAudio: passthrough-handle loaded\n");
    resolve_coreaudio_handle_symbols();
}
#else
static int first_filter_marker;
__attribute__((constructor)) static void idv_audio_stage_loaded(void) { IDV_WRITE_MARKER("IdentityV CoreAudio: filter loaded\n"); }
#endif
#if IDV_AUDIO_STAGE == IDV_STAGE_PASSTHROUGH_HANDLE
static get_data_fn get_real_data(void) { return real_get_data; }
static get_size_fn get_real_size(void) { return real_get_size; }
#else
static void resolve_real_symbols(void) { real_get_data = (get_data_fn)dlsym(RTLD_NEXT, "AudioObjectGetPropertyData"); real_get_size = (get_size_fn)dlsym(RTLD_NEXT, "AudioObjectGetPropertyDataSize"); }
static get_data_fn get_real_data(void) { pthread_once(&real_symbols_once, resolve_real_symbols); return real_get_data; }
static get_size_fn get_real_size(void) { pthread_once(&real_symbols_once, resolve_real_symbols); return real_get_size; }
#endif

#if IDV_AUDIO_STAGE == IDV_STAGE_CALLER || IDV_AUDIO_STAGE == IDV_STAGE_FILTER
static int caller_is_winecoreaudio(void *return_address) { Dl_info info = {0}; return dladdr(return_address, &info) && info.dli_fname && strstr(info.dli_fname, "winecoreaudio") != NULL; }
#endif
#if IDV_AUDIO_STAGE == IDV_STAGE_FILTER
#include "policy.h"
static _Thread_local int hook_depth;
static _Thread_local idv_audio_thread_state_t thread_state;
static int is_system_address(const AudioObjectPropertyAddress *a) { return a && a->mScope == kAudioObjectPropertyScopeGlobal; }
static int refresh_default_input(get_data_fn original) { AudioObjectPropertyAddress input = { kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }; AudioDeviceID device = kAudioObjectUnknown; UInt32 size = sizeof(device); OSStatus status = original(kAudioObjectSystemObject, &input, 0, NULL, &size, &device); if (status != noErr || size != sizeof(device) || device == kAudioObjectUnknown) return 0; idv_audio_note_default_input_result(&thread_state, device, kAudioObjectUnknown); return 1; }
#endif

OSStatus idv_AudioObjectGetPropertyData(AudioObjectID object, const AudioObjectPropertyAddress *address, UInt32 qualifier_size, const void *qualifier, UInt32 *data_size, void *out_data)
{

#if IDV_AUDIO_STAGE == IDV_STAGE_FILTER
    get_data_fn original = get_real_data(); if (!original) return kAudioHardwareUnspecifiedError;
    if (hook_depth++ || !caller_is_winecoreaudio(__builtin_return_address(0)) || object != kAudioObjectSystemObject || !is_system_address(address)) { OSStatus result = original(object, address, qualifier_size, qualifier, data_size, out_data); --hook_depth; return result; }
    UInt32 selector = address->mSelector; OSStatus result; idv_audio_note_selector(&thread_state, selector, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice);
    if (selector == kAudioHardwarePropertyDefaultInputDevice) { result = original(object, address, qualifier_size, qualifier, data_size, out_data); if (result == noErr && data_size && out_data && *data_size == sizeof(AudioDeviceID)) idv_audio_note_default_input_result(&thread_state, *(AudioDeviceID *)out_data, kAudioObjectUnknown); }
    else if (selector == kAudioHardwarePropertyDevices && idv_audio_should_filter_devices(&thread_state, selector, kAudioHardwarePropertyDevices) && refresh_default_input(original) && data_size && out_data && *data_size >= sizeof(AudioDeviceID)) { *(AudioDeviceID *)out_data = (AudioDeviceID)thread_state.last_default_input; *data_size = sizeof(AudioDeviceID); result = noErr; if (__atomic_exchange_n(&first_filter_marker, 1, __ATOMIC_RELAXED) == 0) IDV_WRITE_MARKER("IdentityV CoreAudio: filter narrowed devices\n"); idv_audio_finish_devices_request(&thread_state); }
    else { result = original(object, address, qualifier_size, qualifier, data_size, out_data); if (selector == kAudioHardwarePropertyDevices) idv_audio_finish_devices_request(&thread_state); }
    --hook_depth; return result;
#elif IDV_AUDIO_STAGE == IDV_STAGE_CALLER
    get_data_fn original = get_real_data(); if (!original) return kAudioHardwareUnspecifiedError;
    if (!caller_is_winecoreaudio(__builtin_return_address(0))) return original(object, address, qualifier_size, qualifier, data_size, out_data);
    marker_once("IdentityV CoreAudio: caller matched winecoreaudio\n", sizeof("IdentityV CoreAudio: caller matched winecoreaudio\n") - 1);
    return original(object, address, qualifier_size, qualifier, data_size, out_data);
#elif IDV_AUDIO_STAGE == IDV_STAGE_PASSTHROUGH_HANDLE
    marker_once("IdentityV CoreAudio: passthrough-handle replacement entered\n", sizeof("IdentityV CoreAudio: passthrough-handle replacement entered\n") - 1);
    get_data_fn original = get_real_data(); if (!original) return kAudioHardwareUnspecifiedError;
    return original(object, address, qualifier_size, qualifier, data_size, out_data);
#else
    get_data_fn original = get_real_data(); if (!original) return kAudioHardwareUnspecifiedError;
    marker_once("IdentityV CoreAudio: passthrough replacement entered\n", sizeof("IdentityV CoreAudio: passthrough replacement entered\n") - 1);
    return original(object, address, qualifier_size, qualifier, data_size, out_data);
#endif
}
OSStatus idv_AudioObjectGetPropertyDataSize(AudioObjectID object, const AudioObjectPropertyAddress *address, UInt32 qualifier_size, const void *qualifier, UInt32 *out_size)
{
#if IDV_AUDIO_STAGE == IDV_STAGE_FILTER
    get_size_fn original = get_real_size(); if (!original) return kAudioHardwareUnspecifiedError;
    get_data_fn original_data = get_real_data(); if (hook_depth++ || !caller_is_winecoreaudio(__builtin_return_address(0)) || object != kAudioObjectSystemObject || !is_system_address(address)) { OSStatus result = original(object, address, qualifier_size, qualifier, out_size); --hook_depth; return result; }
    UInt32 selector = address->mSelector; OSStatus result; idv_audio_note_selector(&thread_state, selector, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice);
    if (selector == kAudioHardwarePropertyDevices && original_data && idv_audio_should_filter_devices(&thread_state, selector, kAudioHardwarePropertyDevices) && refresh_default_input(original_data) && out_size) { *out_size = sizeof(AudioDeviceID); result = noErr; if (__atomic_exchange_n(&first_filter_marker, 1, __ATOMIC_RELAXED) == 0) IDV_WRITE_MARKER("IdentityV CoreAudio: filter narrowed devices\n"); } else result = original(object, address, qualifier_size, qualifier, out_size); --hook_depth; return result;
#elif IDV_AUDIO_STAGE == IDV_STAGE_CALLER
    get_size_fn original = get_real_size(); if (!original) return kAudioHardwareUnspecifiedError;
    if (!caller_is_winecoreaudio(__builtin_return_address(0))) return original(object, address, qualifier_size, qualifier, out_size);
    marker_once("IdentityV CoreAudio: caller matched winecoreaudio\n", sizeof("IdentityV CoreAudio: caller matched winecoreaudio\n") - 1);
    return original(object, address, qualifier_size, qualifier, out_size);
#elif IDV_AUDIO_STAGE == IDV_STAGE_PASSTHROUGH_HANDLE
    marker_once("IdentityV CoreAudio: passthrough-handle replacement entered\n", sizeof("IdentityV CoreAudio: passthrough-handle replacement entered\n") - 1);
    get_size_fn original = get_real_size(); if (!original) return kAudioHardwareUnspecifiedError;
    return original(object, address, qualifier_size, qualifier, out_size);
#else
    get_size_fn original = get_real_size(); if (!original) return kAudioHardwareUnspecifiedError;
    marker_once("IdentityV CoreAudio: passthrough replacement entered\n", sizeof("IdentityV CoreAudio: passthrough replacement entered\n") - 1);
    return original(object, address, qualifier_size, qualifier, out_size);
#endif
}
#define DYLD_INTERPOSE(_replacement, _replacee) __attribute__((used)) static struct { const void *replacement; const void *replacee; } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee }
DYLD_INTERPOSE(idv_AudioObjectGetPropertyData, AudioObjectGetPropertyData);
DYLD_INTERPOSE(idv_AudioObjectGetPropertyDataSize, AudioObjectGetPropertyDataSize);
#endif
