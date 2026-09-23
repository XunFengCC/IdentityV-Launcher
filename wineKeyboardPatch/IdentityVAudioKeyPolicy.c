#include "IdentityVAudioKeyPolicy.h"

#include <stddef.h>

static bool is_audio_key(uint16_t keyCode)
{
    return keyCode == IDVAudioKeyCodeF10 ||
           keyCode == IDVAudioKeyCodeF11 ||
           keyCode == IDVAudioKeyCodeF12 ||
           keyCode == IDVAudioKeyCodeF20;
}

static bool *held_for_key(uint16_t keyCode, IDVAudioKeyState *state)
{
    if (keyCode == IDVAudioKeyCodeF10) return &state->f10Down;
    if (keyCode == IDVAudioKeyCodeF11) return &state->f11Down;
    if (keyCode == IDVAudioKeyCodeF12) return &state->f12Down;
    if (keyCode == IDVAudioKeyCodeF20) return &state->f20Down;
    return NULL;
}

static bool *seen_for_key(uint16_t keyCode, IDVAudioKeyState *state)
{
    if (keyCode == IDVAudioKeyCodeF10) return &state->f10SeenDown;
    if (keyCode == IDVAudioKeyCodeF11) return &state->f11SeenDown;
    if (keyCode == IDVAudioKeyCodeF12) return &state->f12SeenDown;
    if (keyCode == IDVAudioKeyCodeF20) return &state->f20SeenDown;
    return NULL;
}

static const bool *const_held_for_key(uint16_t keyCode, const IDVAudioKeyState *state)
{
    if (keyCode == IDVAudioKeyCodeF10) return &state->f10Down;
    if (keyCode == IDVAudioKeyCodeF11) return &state->f11Down;
    if (keyCode == IDVAudioKeyCodeF12) return &state->f12Down;
    if (keyCode == IDVAudioKeyCodeF20) return &state->f20Down;
    return NULL;
}

static IDVAudioKeyAction action_for_key(uint16_t keyCode)
{
    if (keyCode == IDVAudioKeyCodeF10) return IDVAudioKeyActionMute;
    if (keyCode == IDVAudioKeyCodeF11) return IDVAudioKeyActionVolumeDown;
    if (keyCode == IDVAudioKeyCodeF12) return IDVAudioKeyActionVolumeUp;
    if (keyCode == IDVAudioKeyCodeF20) return IDVAudioKeyActionVolumeDown;
    return IDVAudioKeyActionNone;
}

IDVAudioKeyRoute idv_audio_key_route(uint16_t keyCode,
                                     bool keyDown,
                                     bool isRepeat,
                                     bool hasDisallowedModifier,
                                     IDVAudioKeyState *state)
{
    (void)isRepeat;
    IDVAudioKeyRoute route = {
        .recognized = false,
        .consume = false,
        .restoreAsF11 = false,
        .action = IDVAudioKeyActionNone,
    };
    if (!state || !is_audio_key(keyCode)) return route;

    bool *held = held_for_key(keyCode, state);
    bool *seen = seen_for_key(keyCode, state);
    if (!held || !seen) return route;

    if (keyDown) {
        /* One physical down owns the routing decision until its up arrives. */
        if (*seen) {
            if (keyCode == IDVAudioKeyCodeF20 && state->f20ForwardedAsF11) {
                route.recognized = true;
                route.restoreAsF11 = true;
                return route;
            }
            if (!*held) return route;
            route.recognized = true;
            route.consume = true;
            /* A modifier added while held must not leak an unmatched key-down. */
            if (!hasDisallowedModifier && keyCode != IDVAudioKeyCodeF10)
                route.action = action_for_key(keyCode);
            return route;
        }

        *seen = true;

        /* Command/Control/Option keep their normal Wine/game mapping. Fn is allowed. */
        if (keyCode == IDVAudioKeyCodeF20 && hasDisallowedModifier) {
            state->f20ForwardedAsF11 = true;
            route.recognized = true;
            route.restoreAsF11 = true;
            return route;
        }
        if (hasDisallowedModifier) return route;

        route.recognized = true;
        route.consume = true;
        *held = true;

        if (keyCode == IDVAudioKeyCodeF10) {
            /* A held mute key is consumed, but only the first down toggles mute. */
            route.action = IDVAudioKeyActionMute;
        } else {
            /* F11/F12 repeats intentionally produce another volume step. */
            route.action = action_for_key(keyCode);
        }
        return route;
    }

    /* Do not eat an up event for a key-down that never belonged to us. */
    if (!*seen) return route;
    bool wasOwned = *held;
    bool wasForwarded = keyCode == IDVAudioKeyCodeF20 && state->f20ForwardedAsF11;
    *seen = false;
    *held = false;
    if (keyCode == IDVAudioKeyCodeF20) state->f20ForwardedAsF11 = false;
    if (wasForwarded) {
        route.recognized = true;
        route.restoreAsF11 = true;
        return route;
    }
    if (!wasOwned) return route;
    route.recognized = true;
    route.consume = true;
    return route;
}

void idv_audio_key_reject_ownership(uint16_t keyCode, IDVAudioKeyState *state)
{
    bool *held = state ? held_for_key(keyCode, state) : NULL;
    if (held) *held = false;
    if (state && keyCode == IDVAudioKeyCodeF20) state->f20ForwardedAsF11 = true;
}

bool idv_audio_key_is_owned(uint16_t keyCode, const IDVAudioKeyState *state)
{
    const bool *held = state ? const_held_for_key(keyCode, state) : NULL;
    return held && *held;
}

bool idv_audio_key_is_forwarded_as_f11(uint16_t keyCode, const IDVAudioKeyState *state)
{
    return keyCode == IDVAudioKeyCodeF20 && state && state->f20ForwardedAsF11;
}

float idv_audio_next_volume(float current, bool increase, bool fine)
{
    const float step = fine ? (1.0f / 64.0f) : (1.0f / 16.0f);
    float next = increase ? current + step : current - step;
    if (next < 0.0f) return 0.0f;
    if (next > 1.0f) return 1.0f;
    return next;
}

bool idv_audio_next_mute(bool muted)
{
    return !muted;
}
