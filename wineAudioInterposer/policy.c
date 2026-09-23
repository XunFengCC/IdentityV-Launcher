#include "policy.h"

void idv_audio_note_selector(idv_audio_thread_state_t *state,
                             uint32_t selector,
                             uint32_t default_input_selector,
                             uint32_t default_output_selector)
{
    if (selector == default_input_selector) {
        state->flow = IDV_AUDIO_FLOW_CAPTURE;
        state->has_default_input = 0;
    } else if (selector == default_output_selector) {
        state->flow = IDV_AUDIO_FLOW_RENDER;
        state->has_default_input = 0;
    }
}

int idv_audio_should_filter_devices(const idv_audio_thread_state_t *state,
                                    uint32_t selector,
                                    uint32_t devices_selector)
{
    return selector == devices_selector &&
           state->flow == IDV_AUDIO_FLOW_CAPTURE &&
           state->has_default_input;
}

void idv_audio_note_default_input_result(idv_audio_thread_state_t *state,
                                         uint32_t device_id,
                                         uint32_t unknown_device_id)
{
    if (state->flow != IDV_AUDIO_FLOW_CAPTURE) return;
    if (device_id == unknown_device_id) return;
    state->last_default_input = device_id;
    state->has_default_input = 1;
}

void idv_audio_finish_devices_request(idv_audio_thread_state_t *state)
{
    state->flow = IDV_AUDIO_FLOW_NONE;
    state->has_default_input = 0;
}
