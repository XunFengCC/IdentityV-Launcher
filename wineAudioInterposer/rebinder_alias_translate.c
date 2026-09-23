#include "rebinder_alias_translate.h"

static const CFStringRef alias_uid = CFSTR("com.xunfeng.identityv.system-default-input.v1");

int idv_alias_translate_matches(AudioObjectID object, const AudioObjectPropertyAddress *address,
                                UInt32 qualifier_size, const void *qualifier,
                                UInt32 *data_size, void *out_data)
{
    if (object != kAudioObjectSystemObject || !address ||
        address->mSelector != kAudioHardwarePropertyTranslateUIDToDevice ||
        address->mScope != kAudioObjectPropertyScopeGlobal ||
        address->mElement != kAudioObjectPropertyElementMain ||
        qualifier_size != sizeof(CFStringRef) || !qualifier || !data_size || !out_data ||
        *data_size < sizeof(AudioDeviceID)) return 0;
    CFStringRef uid = *(const CFStringRef *)qualifier;
    return uid && CFEqual(uid, alias_uid);
}

OSStatus idv_alias_translate(idv_rebinder_filter_state_t *state, idv_alias_get_data_fn original,
                             UInt32 *data_size, void *out_data)
{
    AudioObjectPropertyAddress input = { kAudioHardwarePropertyDefaultInputDevice,
                                         kAudioObjectPropertyScopeGlobal,
                                         kAudioObjectPropertyElementMain };
    UInt32 size = sizeof(AudioDeviceID);
    AudioDeviceID device = kAudioObjectUnknown;
    if (state) idv_reset(state);
    *(AudioDeviceID *)out_data = kAudioObjectUnknown;
    if (!original) return kAudioHardwareUnspecifiedError;
    OSStatus status = original(kAudioObjectSystemObject, &input, 0, NULL, &size, &device);
    if (status == noErr && size == sizeof(device) && device != kAudioObjectUnknown) {
        *(AudioDeviceID *)out_data = device;
        *data_size = sizeof(device);
        return noErr;
    }
    return kAudioHardwareUnspecifiedError;
}
