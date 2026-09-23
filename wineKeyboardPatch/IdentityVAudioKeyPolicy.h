#ifndef IDV_AUDIO_KEY_POLICY_H
#define IDV_AUDIO_KEY_POLICY_H

#include <Carbon/Carbon.h>
#include <stdbool.h>
#include <stdint.h>

/* Carbon virtual key codes for keys handled by the forwarder. */
enum {
    IDVAudioKeyCodeF10 = kVK_F10,
    IDVAudioKeyCodeF11 = kVK_F11,
    IDVAudioKeyCodeF12 = kVK_F12,
    IDVAudioKeyCodeF20 = kVK_F20,
};

typedef enum {
    IDVAudioKeyActionNone = 0,
    IDVAudioKeyActionMute,
    IDVAudioKeyActionVolumeDown,
    IDVAudioKeyActionVolumeUp,
} IDVAudioKeyAction;

typedef struct {
    /* A seen key-down stays associated until its key-up, even if we reject ownership. */
    bool f10SeenDown;
    bool f11SeenDown;
    bool f12SeenDown;
    bool f20SeenDown;
    bool f10Down;
    bool f11Down;
    bool f12Down;
    bool f20Down;
    bool f20ForwardedAsF11;
} IDVAudioKeyState;

typedef struct {
    bool recognized;
    bool consume;
    bool restoreAsF11;
    IDVAudioKeyAction action;
} IDVAudioKeyRoute;

/*
 * Routes one local key event and updates state only for an event that belongs
 * to this forwarder.  A key-up is consumed only after its corresponding
 * key-down was accepted, which prevents an unrelated key-up from disappearing
 * into the monitor.
 */
IDVAudioKeyRoute idv_audio_key_route(uint16_t keyCode,
                                     bool keyDown,
                                     bool isRepeat,
                                     bool hasDisallowedModifier,
                                     IDVAudioKeyState *state);

/* Drop ownership after a capability probe failed, while retaining the physical key-down. */
void idv_audio_key_reject_ownership(uint16_t keyCode, IDVAudioKeyState *state);

bool idv_audio_key_is_owned(uint16_t keyCode, const IDVAudioKeyState *state);

bool idv_audio_key_is_forwarded_as_f11(uint16_t keyCode, const IDVAudioKeyState *state);

/* The normal step follows the keyboard volume-key feel; Shift uses a finer step. */
float idv_audio_next_volume(float current, bool increase, bool fine);

bool idv_audio_next_mute(bool muted);

#endif
