#include "policy.h"
#include <assert.h>
#include <stdio.h>

enum { DefaultInput = 10, DefaultOutput = 11, Devices = 12, Unknown = 0 };

int main(void)
{
    idv_audio_thread_state_t state = {0};
    idv_audio_note_selector(&state, DefaultInput, DefaultInput, DefaultOutput);
    idv_audio_note_default_input_result(&state, 42, Unknown);
    assert(idv_audio_should_filter_devices(&state, Devices, Devices));
    idv_audio_finish_devices_request(&state);
    assert(!idv_audio_should_filter_devices(&state, Devices, Devices));

    idv_audio_note_selector(&state, DefaultOutput, DefaultInput, DefaultOutput);
    assert(!idv_audio_should_filter_devices(&state, Devices, Devices));

    idv_audio_note_selector(&state, DefaultInput, DefaultInput, DefaultOutput);
    idv_audio_note_default_input_result(&state, Unknown, Unknown);
    assert(!idv_audio_should_filter_devices(&state, Devices, Devices));
    puts("policy test passed");
    return 0;
}
