#ifndef IDENTITYV_AUDIO_INTERPOSER_POLICY_H
#define IDENTITYV_AUDIO_INTERPOSER_POLICY_H

#include <stdint.h>

/*
 * Pure state machine shared by the interposer and its non-CoreAudio test.
 * Selectors are supplied by the caller so this header is architecture- and
 * platform-SDK-independent.
 */
typedef enum {
    IDV_AUDIO_FLOW_NONE = 0,
    IDV_AUDIO_FLOW_RENDER,
    IDV_AUDIO_FLOW_CAPTURE,
} idv_audio_flow_t;

typedef struct {
    idv_audio_flow_t flow;
    uint32_t last_default_input;
    int has_default_input;
} idv_audio_thread_state_t;

void idv_audio_note_selector(idv_audio_thread_state_t *state,
                             uint32_t selector,
                             uint32_t default_input_selector,
                             uint32_t default_output_selector);

int idv_audio_should_filter_devices(const idv_audio_thread_state_t *state,
                                    uint32_t selector,
                                    uint32_t devices_selector);

void idv_audio_note_default_input_result(idv_audio_thread_state_t *state,
                                         uint32_t device_id,
                                         uint32_t unknown_device_id);

void idv_audio_finish_devices_request(idv_audio_thread_state_t *state);

#endif
