#include "rebinder_alias_translate.h"
#include <assert.h>

static AudioDeviceID mock_device;
static OSStatus mock_status;
static OSStatus mock_default(AudioObjectID object, const AudioObjectPropertyAddress *address,
                             UInt32 qualifier_size, const void *qualifier, UInt32 *size, void *out_data)
{
    assert(object == kAudioObjectSystemObject);
    assert(address->mSelector == kAudioHardwarePropertyDefaultInputDevice);
    assert(qualifier_size == 0 && !qualifier);
    *(AudioDeviceID *)out_data = mock_device;
    *size = sizeof(mock_device);
    return mock_status;
}

static AudioObjectPropertyAddress translate_address(UInt32 scope, UInt32 element)
{
    AudioObjectPropertyAddress address = { kAudioHardwarePropertyTranslateUIDToDevice, scope, element };
    return address;
}

static void full_transcript(idv_rebinder_filter_state_t *state, AudioDeviceID device)
{
    uint32_t observed = 0;
    assert(idv_note_default(state, device, kAudioObjectUnknown));
    assert(idv_note_size(state));
    assert(idv_take_alias_data(state, &observed) && observed == device);
    assert(idv_alias_accept(state, device, IDV_ALIAS_STREAM_SIZE));
    assert(idv_alias_accept(state, device, IDV_ALIAS_STREAM_DATA));
    assert(idv_alias_accept(state, device, IDV_ALIAS_NAME));
    assert(idv_alias_accept(state, device, IDV_ALIAS_UID));
    assert(state->state == IDV_IDLE);
}

int main(void)
{
    idv_rebinder_filter_state_t state = {0};
    CFStringRef alias = CFSTR("com.xunfeng.identityv.system-default-input.v1");
    CFStringRef other = CFSTR("other");
    CFStringRef nil_uid = NULL;
    AudioObjectPropertyAddress correct = translate_address(kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    AudioObjectPropertyAddress wrong_scope = translate_address(kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain);
    AudioObjectPropertyAddress wrong_element = translate_address(kAudioObjectPropertyScopeGlobal, 1);
    AudioDeviceID output = 99;
    UInt32 size = sizeof(output);

    assert(idv_alias_translate_matches(kAudioObjectSystemObject, &correct, sizeof(alias), &alias, &size, &output));
    assert(!idv_alias_translate_matches(kAudioObjectSystemObject, &wrong_scope, sizeof(alias), &alias, &size, &output));
    assert(!idv_alias_translate_matches(kAudioObjectSystemObject, &wrong_element, sizeof(alias), &alias, &size, &output));
    assert(!idv_alias_translate_matches(kAudioObjectSystemObject, &correct, sizeof(alias) - 1, &alias, &size, &output));
    assert(!idv_alias_translate_matches(kAudioObjectSystemObject, &correct, sizeof(alias), NULL, &size, &output));
    assert(!idv_alias_translate_matches(kAudioObjectSystemObject, &correct, sizeof(nil_uid), &nil_uid, &size, &output));
    assert(!idv_alias_translate_matches(kAudioObjectSystemObject, &correct, sizeof(other), &other, &size, &output));

    full_transcript(&state, 7);
    assert(idv_note_default(&state, 7, kAudioObjectUnknown));
    assert(idv_note_size(&state));
    uint32_t observed = 0;
    assert(idv_take_alias_data(&state, &observed) && observed == 7);
    mock_status = noErr; mock_device = 7; size = sizeof(output); output = 0;
    assert(idv_alias_translate(&state, mock_default, &size, &output) == noErr);
    assert(output == 7 && state.state == IDV_IDLE);
    assert(!idv_alias_accept(&state, 7, IDV_ALIAS_STREAM_SIZE));
    mock_device = 8; size = sizeof(output); output = 0;
    assert(idv_alias_translate(&state, mock_default, &size, &output) == noErr && output == 8);
    mock_status = kAudioHardwareUnspecifiedError; output = 123;
    assert(idv_alias_translate(&state, mock_default, &size, &output) == kAudioHardwareUnspecifiedError);
    assert(output == kAudioObjectUnknown && state.state == IDV_IDLE);
    return 0;
}
