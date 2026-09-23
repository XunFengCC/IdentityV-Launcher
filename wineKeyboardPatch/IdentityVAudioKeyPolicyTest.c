#include "IdentityVAudioKeyPolicy.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>

static void test_plain_and_fn_routing(void)
{
    IDVAudioKeyState state = {0};

    IDVAudioKeyRoute f10 = idv_audio_key_route(IDVAudioKeyCodeF10, true, false, false, &state);
    assert(f10.recognized && f10.consume && f10.action == IDVAudioKeyActionMute);

    IDVAudioKeyRoute f10Repeat = idv_audio_key_route(IDVAudioKeyCodeF10, true, true, false, &state);
    assert(f10Repeat.recognized && f10Repeat.consume && f10Repeat.action == IDVAudioKeyActionNone);

    IDVAudioKeyRoute f10Up = idv_audio_key_route(IDVAudioKeyCodeF10, false, false, false, &state);
    assert(f10Up.recognized && f10Up.consume && f10Up.action == IDVAudioKeyActionNone);

    IDVAudioKeyRoute strayUp = idv_audio_key_route(IDVAudioKeyCodeF10, false, false, false, &state);
    assert(!strayUp.recognized && !strayUp.consume);

    /* Fn is deliberately not represented as a disallowed modifier. */
    IDVAudioKeyRoute f11WithFn = idv_audio_key_route(IDVAudioKeyCodeF11, true, false, false, &state);
    assert(f11WithFn.recognized && f11WithFn.consume && f11WithFn.action == IDVAudioKeyActionVolumeDown);
    IDVAudioKeyRoute f11Repeat = idv_audio_key_route(IDVAudioKeyCodeF11, true, true, false, &state);
    assert(f11Repeat.action == IDVAudioKeyActionVolumeDown);
    (void)idv_audio_key_route(IDVAudioKeyCodeF11, false, false, false, &state);

    IDVAudioKeyRoute commandF12 = idv_audio_key_route(IDVAudioKeyCodeF12, true, false, true, &state);
    assert(!commandF12.recognized && !commandF12.consume);
    IDVAudioKeyRoute commandF12Up = idv_audio_key_route(IDVAudioKeyCodeF12, false, false, true, &state);
    assert(!commandF12Up.recognized && !commandF12Up.consume);

    /* If the first probe fails, later repeats must keep following the game-bound path. */
    IDVAudioKeyRoute unavailableF11 = idv_audio_key_route(IDVAudioKeyCodeF11, true, false, false, &state);
    assert(unavailableF11.consume && unavailableF11.action == IDVAudioKeyActionVolumeDown);
    assert(idv_audio_key_is_owned(IDVAudioKeyCodeF11, &state));
    idv_audio_key_reject_ownership(IDVAudioKeyCodeF11, &state);
    assert(!idv_audio_key_is_owned(IDVAudioKeyCodeF11, &state));
    IDVAudioKeyRoute unavailableRepeat = idv_audio_key_route(IDVAudioKeyCodeF11, true, true, false, &state);
    assert(!unavailableRepeat.recognized && !unavailableRepeat.consume);
    IDVAudioKeyRoute unavailableUp = idv_audio_key_route(IDVAudioKeyCodeF11, false, false, false, &state);
    assert(!unavailableUp.recognized && !unavailableUp.consume);

    /* A modifier added after ownership keeps repeats/up events with this monitor. */
    IDVAudioKeyRoute ownedF12 = idv_audio_key_route(IDVAudioKeyCodeF12, true, false, false, &state);
    assert(ownedF12.consume && ownedF12.action == IDVAudioKeyActionVolumeUp);
    IDVAudioKeyRoute modifiedRepeat = idv_audio_key_route(IDVAudioKeyCodeF12, true, true, true, &state);
    assert(modifiedRepeat.recognized && modifiedRepeat.consume &&
           modifiedRepeat.action == IDVAudioKeyActionNone);
    IDVAudioKeyRoute modifiedUp = idv_audio_key_route(IDVAudioKeyCodeF12, false, false, true, &state);
    assert(modifiedUp.recognized && modifiedUp.consume);

    /* The HID lease presents physical F11 as F20. Plain F20 is volume down. */
    IDVAudioKeyRoute f20 = idv_audio_key_route(IDVAudioKeyCodeF20, true, false, false, &state);
    assert(f20.recognized && f20.consume && f20.action == IDVAudioKeyActionVolumeDown);
    IDVAudioKeyRoute f20RepeatWithCommand = idv_audio_key_route(IDVAudioKeyCodeF20, true, true, true, &state);
    assert(f20RepeatWithCommand.recognized && f20RepeatWithCommand.consume &&
           f20RepeatWithCommand.action == IDVAudioKeyActionNone);
    IDVAudioKeyRoute f20Up = idv_audio_key_route(IDVAudioKeyCodeF20, false, false, true, &state);
    assert(f20Up.recognized && f20Up.consume);

    /* A modified F11 must reach Wine as F11 even though HID delivered F20. */
    IDVAudioKeyRoute commandF20 = idv_audio_key_route(IDVAudioKeyCodeF20, true, false, true, &state);
    assert(commandF20.recognized && !commandF20.consume && commandF20.restoreAsF11);
    IDVAudioKeyRoute commandF20Up = idv_audio_key_route(IDVAudioKeyCodeF20, false, false, false, &state);
    assert(commandF20Up.recognized && !commandF20Up.consume && commandF20Up.restoreAsF11);

    /* If audio capability is unavailable, the physical F11 association is retained. */
    IDVAudioKeyRoute unavailableF20 = idv_audio_key_route(IDVAudioKeyCodeF20, true, false, false, &state);
    assert(unavailableF20.consume && unavailableF20.action == IDVAudioKeyActionVolumeDown);
    idv_audio_key_reject_ownership(IDVAudioKeyCodeF20, &state);
    assert(idv_audio_key_is_forwarded_as_f11(IDVAudioKeyCodeF20, &state));

    /* A different key may arrive while the forwarded F20 is still held. Its
       failed probe must not turn that key's event into another F11. */
    IDVAudioKeyRoute unavailableF12WhileF20 = idv_audio_key_route(IDVAudioKeyCodeF12, true, false, false, &state);
    assert(unavailableF12WhileF20.consume && unavailableF12WhileF20.action == IDVAudioKeyActionVolumeUp);
    idv_audio_key_reject_ownership(IDVAudioKeyCodeF12, &state);
    assert(!idv_audio_key_is_forwarded_as_f11(IDVAudioKeyCodeF12, &state));
    assert(idv_audio_key_is_forwarded_as_f11(IDVAudioKeyCodeF20, &state));
    IDVAudioKeyRoute unavailableF12Up = idv_audio_key_route(IDVAudioKeyCodeF12, false, false, false, &state);
    assert(!unavailableF12Up.recognized && !unavailableF12Up.consume);

    IDVAudioKeyRoute unavailableF20Repeat = idv_audio_key_route(IDVAudioKeyCodeF20, true, true, true, &state);
    assert(unavailableF20Repeat.restoreAsF11 && !unavailableF20Repeat.consume);
    IDVAudioKeyRoute unavailableF20Up = idv_audio_key_route(IDVAudioKeyCodeF20, false, false, false, &state);
    assert(unavailableF20Up.restoreAsF11 && !unavailableF20Up.consume);
    assert(!idv_audio_key_is_forwarded_as_f11(IDVAudioKeyCodeF20, &state));
}

static void test_fake_volume_backend(void)
{
    /* A tiny fake backend exercises the same policy used by CoreAudio. */
    float left = 0.50f;
    float right = 0.50f;
    bool muted = false;

    muted = idv_audio_next_mute(muted);
    assert(muted);
    assert(fabsf(idv_audio_next_volume(left, false, false) - 0.4375f) < 0.0001f);
    assert(fabsf(idv_audio_next_volume(right, true, true) - 0.515625f) < 0.0001f);
    assert(idv_audio_next_volume(0.0f, false, false) == 0.0f);
    assert(idv_audio_next_volume(1.0f, true, false) == 1.0f);
    assert(idv_audio_next_mute(muted) == false);
}

int main(void)
{
    test_plain_and_fn_routing();
    test_fake_volume_backend();
    puts("IdentityV audio-key policy tests passed");
    return 0;
}
