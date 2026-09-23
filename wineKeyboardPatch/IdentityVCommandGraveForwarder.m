#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <CoreAudio/CoreAudio.h>

#include "IdentityVAudioKeyPolicy.h"

#include <dispatch/dispatch.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>

/*
 * Command+grave is AppKit's window-cycle shortcut.  Hand the physical event
 * straight to WineWindow; Wine then applies its own Command-to-Alt mapping.
 *
 * The F10-F12 path below is intentionally limited to audio actions in this
 * same process. Physical F11 may arrive here as F20 while the foreground
 * function-key controller's public UserKeyMapping lease is active; the policy
 * routes plain F20 to volume down and restores modified F20 back to F11.
 * On 2026-09-18 an experiment
 * tried to give F7-F12 back to macOS while the game kept F1-F6, by consuming
 * plain F presses and performing the media action directly (posting a
 * system-defined media key is not honored on this macOS build).  Measurement
 * then showed the F row on this Mac is all-or-nothing per HIDFKeyMode: with
 * "standard F1-F12" every F key reaches the application and carries the
 * Function modifier flag either way, so a plain F press and Fn+F press cannot
 * be told apart; with "media keys" the whole row is consumed by the system
 * before any application or even a session event tap sees it.  Wind decided to
 * keep the whole row mapped to standard function keys, so the conversion code,
 * its headers and its tests were removed rather than left dormant.
 *
 * Ordinary Command+digit/letter chords keep using Wine's native mapping; this
 * monitor must never post key events for them (the 2026-08-31 direct-post
 * candidate was rejected for batching down/up).
 */

static id commandGraveMonitor;
static IDVAudioKeyState audioKeyState;
static dispatch_queue_t audioQueue;
static _Atomic(uint32_t) audioCapabilityMask;
static _Atomic(bool) audioCapabilityProbePending;

enum {
    IDVAudioCapabilityMute = 1u << 0,
    IDVAudioCapabilityVolume = 1u << 1,
};

enum {
    IDVAudioMaxOutputChannels = 64,
};

static dispatch_queue_t audioActionQueue(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        audioQueue = dispatch_queue_create("com.xunfeng.identityv.audio-key-actions",
                                            DISPATCH_QUEUE_SERIAL);
    });
    return audioQueue;
}

static AudioObjectPropertyAddress outputPropertyAddress(AudioObjectPropertySelector selector,
                                                         AudioObjectPropertyElement element)
{
    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope = kAudioObjectPropertyScopeOutput,
        .mElement = element,
    };
    return address;
}

static BOOL defaultOutputDevice(AudioDeviceID *device)
{
    if (!device) return NO;

    AudioObjectPropertyAddress address = {
        .mSelector = kAudioHardwarePropertyDefaultOutputDevice,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    UInt32 size = sizeof(*device);
    AudioDeviceID candidate = kAudioObjectUnknown;
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                                  &address,
                                                  0,
                                                  NULL,
                                                  &size,
                                                  &candidate);
    if (status != noErr || candidate == kAudioObjectUnknown || candidate == 0)
        return NO;

    *device = candidate;
    return YES;
}

static BOOL writableOutputProperty(AudioDeviceID device,
                                   AudioObjectPropertySelector selector,
                                   AudioObjectPropertyElement element)
{
    AudioObjectPropertyAddress address = outputPropertyAddress(selector, element);
    if (!AudioObjectHasProperty(device, &address)) return NO;

    Boolean settable = false;
    OSStatus status = AudioObjectIsPropertySettable(device, &address, &settable);
    return status == noErr && settable;
}

static BOOL readUInt32OutputProperty(AudioDeviceID device,
                                      AudioObjectPropertySelector selector,
                                      AudioObjectPropertyElement element,
                                      UInt32 *value)
{
    if (!value) return NO;
    AudioObjectPropertyAddress address = outputPropertyAddress(selector, element);
    UInt32 size = sizeof(*value);
    return AudioObjectGetPropertyData(device, &address, 0, NULL, &size, value) == noErr;
}

static BOOL writeUInt32OutputProperty(AudioDeviceID device,
                                       AudioObjectPropertySelector selector,
                                       AudioObjectPropertyElement element,
                                       UInt32 value)
{
    AudioObjectPropertyAddress address = outputPropertyAddress(selector, element);
    UInt32 size = sizeof(value);
    return AudioObjectSetPropertyData(device, &address, 0, NULL, size, &value) == noErr;
}

static BOOL readFloatOutputProperty(AudioDeviceID device,
                                    AudioObjectPropertySelector selector,
                                    AudioObjectPropertyElement element,
                                    Float32 *value)
{
    if (!value) return NO;
    AudioObjectPropertyAddress address = outputPropertyAddress(selector, element);
    UInt32 size = sizeof(*value);
    return AudioObjectGetPropertyData(device, &address, 0, NULL, &size, value) == noErr;
}

static BOOL writeFloatOutputProperty(AudioDeviceID device,
                                     AudioObjectPropertySelector selector,
                                     AudioObjectPropertyElement element,
                                     Float32 value)
{
    AudioObjectPropertyAddress address = outputPropertyAddress(selector, element);
    UInt32 size = sizeof(value);
    return AudioObjectSetPropertyData(device, &address, 0, NULL, size, &value) == noErr;
}

/* Return the number of output channels without enumerating any other device. */
static UInt32 outputChannelCount(AudioDeviceID device)
{
    AudioObjectPropertyAddress address = outputPropertyAddress(kAudioDevicePropertyStreamConfiguration,
                                                                kAudioObjectPropertyElementMain);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr || size == 0)
        return 0;

    AudioBufferList *list = malloc(size);
    if (!list) return 0;

    UInt32 channels = 0;
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, list) == noErr) {
        size_t headerSize = offsetof(AudioBufferList, mBuffers);
        if (size >= headerSize &&
            list->mNumberBuffers <= (size - headerSize) / sizeof(AudioBuffer)) {
            for (UInt32 index = 0; index < list->mNumberBuffers; index++) {
                UInt32 next = channels + list->mBuffers[index].mNumberChannels;
                if (next < channels || next > IDVAudioMaxOutputChannels) {
                    channels = IDVAudioMaxOutputChannels;
                    break;
                }
                channels = next;
            }
        }
    }

    free(list);
    return channels;
}

static UInt32 writableOutputChannels(AudioDeviceID device,
                                     AudioObjectPropertySelector selector,
                                     AudioObjectPropertyElement *elements,
                                     UInt32 capacity)
{
    if (!elements || capacity == 0) return 0;
    UInt32 count = outputChannelCount(device);
    if (count > capacity) count = capacity;

    UInt32 writable = 0;
    for (UInt32 channel = 1; channel <= count; channel++) {
        if (writableOutputProperty(device, selector, channel))
            elements[writable++] = channel;
    }
    return writable;
}

static BOOL hasWritableAudioControl(AudioDeviceID device, IDVAudioKeyAction action)
{
    AudioObjectPropertySelector selector = (action == IDVAudioKeyActionMute)
        ? kAudioDevicePropertyMute
        : kAudioDevicePropertyVolumeScalar;
    if (writableOutputProperty(device, selector, kAudioObjectPropertyElementMain)) {
        if (action == IDVAudioKeyActionMute) {
            UInt32 current = 0;
            if (readUInt32OutputProperty(device,
                                         selector,
                                         kAudioObjectPropertyElementMain,
                                         &current))
                return YES;
        } else {
            Float32 current = 0.0f;
            if (readFloatOutputProperty(device,
                                        selector,
                                        kAudioObjectPropertyElementMain,
                                        &current) &&
                isfinite(current))
                return YES;
        }
    }

    AudioObjectPropertyElement elements[IDVAudioMaxOutputChannels];
    UInt32 count = writableOutputChannels(device, selector, elements, IDVAudioMaxOutputChannels);
    for (UInt32 index = 0; index < count; index++) {
        if (action == IDVAudioKeyActionMute) {
            UInt32 current = 0;
            if (readUInt32OutputProperty(device, selector, elements[index], &current))
                return YES;
        } else {
            Float32 current = 0.0f;
            if (readFloatOutputProperty(device, selector, elements[index], &current) &&
                isfinite(current))
                return YES;
        }
    }
    return NO;
}

static uint32_t capabilityBitForAction(IDVAudioKeyAction action)
{
    if (action == IDVAudioKeyActionMute) return IDVAudioCapabilityMute;
    if (action == IDVAudioKeyActionVolumeDown || action == IDVAudioKeyActionVolumeUp)
        return IDVAudioCapabilityVolume;
    return 0;
}

static BOOL cachedAudioActionAvailable(IDVAudioKeyAction action)
{
    uint32_t bit = capabilityBitForAction(action);
    uint32_t mask = atomic_load_explicit(&audioCapabilityMask, memory_order_acquire);
    return bit != 0 && (mask & bit) != 0;
}

static void refreshAudioCapabilities(void)
{
    AudioDeviceID device = kAudioObjectUnknown;
    uint32_t mask = 0;
    if (defaultOutputDevice(&device)) {
        if (hasWritableAudioControl(device, IDVAudioKeyActionMute))
            mask |= IDVAudioCapabilityMute;
        if (hasWritableAudioControl(device, IDVAudioKeyActionVolumeDown))
            mask |= IDVAudioCapabilityVolume;
    }
    atomic_store_explicit(&audioCapabilityMask, mask, memory_order_release);
}

static void installDefaultOutputListener(void);

static void scheduleAudioCapabilityProbe(void)
{
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(&audioCapabilityProbePending,
                                                 &expected,
                                                 true,
                                                 memory_order_acq_rel,
                                                 memory_order_acquire))
        return;

    dispatch_async(audioActionQueue(), ^{
        installDefaultOutputListener();
        refreshAudioCapabilities();
        atomic_store_explicit(&audioCapabilityProbePending, false, memory_order_release);
    });
}

static void installDefaultOutputListener(void)
{
    /* This function is called only on audioActionQueue. */
    static BOOL installed;
    if (installed) return;

    AudioObjectPropertyAddress address = {
        .mSelector = kAudioHardwarePropertyDefaultOutputDevice,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    OSStatus status = AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject,
                                                           &address,
                                                           audioActionQueue(),
                                                           ^(UInt32 numberAddresses,
                                                             const AudioObjectPropertyAddress *addresses) {
        (void)numberAddresses;
        (void)addresses;
        atomic_store_explicit(&audioCapabilityMask, 0, memory_order_release);
        scheduleAudioCapabilityProbe();
    });
    if (status == noErr) {
        installed = YES;
    } else {
        fprintf(stderr, "IdentityV audio key capability listener unavailable: status=%d\n", (int)status);
    }
}

static BOOL performMute(AudioDeviceID device)
{
    if (writableOutputProperty(device,
                               kAudioDevicePropertyMute,
                               kAudioObjectPropertyElementMain)) {
        UInt32 current = 0;
        if (readUInt32OutputProperty(device,
                                     kAudioDevicePropertyMute,
                                     kAudioObjectPropertyElementMain,
                                     &current)) {
            UInt32 next = idv_audio_next_mute(current != 0) ? 1 : 0;
            return writeUInt32OutputProperty(device,
                                             kAudioDevicePropertyMute,
                                             kAudioObjectPropertyElementMain,
                                             next);
        }
    }

    AudioObjectPropertyElement elements[IDVAudioMaxOutputChannels];
    UInt32 count = writableOutputChannels(device,
                                          kAudioDevicePropertyMute,
                                          elements,
                                          IDVAudioMaxOutputChannels);
    if (count == 0) return NO;

    UInt32 current[IDVAudioMaxOutputChannels];
    BOOL anyUnmuted = NO;
    UInt32 readable = 0;
    for (UInt32 index = 0; index < count; index++) {
        if (!readUInt32OutputProperty(device,
                                      kAudioDevicePropertyMute,
                                      elements[index],
                                      &current[readable]))
            continue;
        if (current[readable] == 0) anyUnmuted = YES;
        elements[readable] = elements[index];
        readable++;
    }
    if (readable == 0) return NO;

    UInt32 target = anyUnmuted ? 1 : 0;
    BOOL wrote = NO;
    for (UInt32 index = 0; index < readable; index++) {
        if (writeUInt32OutputProperty(device,
                                      kAudioDevicePropertyMute,
                                      elements[index],
                                      target))
            wrote = YES;
    }
    return wrote;
}

/* Volume keys should restore audible output when the same device is muted. */
static BOOL clearMuteIfNeeded(AudioDeviceID device)
{
    UInt32 mainMute = 0;
    BOOL mainWasMuted = NO;
    if (readUInt32OutputProperty(device,
                                 kAudioDevicePropertyMute,
                                 kAudioObjectPropertyElementMain,
                                 &mainMute)) {
        if (mainMute == 0) return YES;
        mainWasMuted = YES;
        if (writableOutputProperty(device,
                                   kAudioDevicePropertyMute,
                                   kAudioObjectPropertyElementMain)) {
            return writeUInt32OutputProperty(device,
                                             kAudioDevicePropertyMute,
                                             kAudioObjectPropertyElementMain,
                                             0);
        }
    }

    AudioObjectPropertyElement elements[IDVAudioMaxOutputChannels];
    UInt32 count = writableOutputChannels(device,
                                          kAudioDevicePropertyMute,
                                          elements,
                                          IDVAudioMaxOutputChannels);
    if (count == 0) return !mainWasMuted;

    BOOL readable[IDVAudioMaxOutputChannels] = {0};
    BOOL anyReadable = NO;
    BOOL anyMuted = NO;
    for (UInt32 index = 0; index < count; index++) {
        UInt32 current = 0;
        if (readUInt32OutputProperty(device,
                                     kAudioDevicePropertyMute,
                                     elements[index],
                                     &current)) {
            readable[index] = YES;
            anyReadable = YES;
            if (current != 0) anyMuted = YES;
        }
    }
    if (!anyReadable) return !mainWasMuted;
    if (!anyMuted) return !mainWasMuted;

    BOOL wrote = NO;
    for (UInt32 index = 0; index < count; index++) {
        if (readable[index] &&
            writeUInt32OutputProperty(device,
                                      kAudioDevicePropertyMute,
                                      elements[index],
                                      0))
            wrote = YES;
    }
    return wrote;
}

static Float32 clampedVolume(Float32 current)
{
    if (!isfinite(current)) return current;
    if (current < 0.0f) return 0.0f;
    if (current > 1.0f) return 1.0f;
    return current;
}

static BOOL performVolume(AudioDeviceID device, BOOL increase, BOOL fine)
{
    if (writableOutputProperty(device,
                               kAudioDevicePropertyVolumeScalar,
                               kAudioObjectPropertyElementMain)) {
        Float32 current = 0.0f;
        if (readFloatOutputProperty(device,
                                    kAudioDevicePropertyVolumeScalar,
                                    kAudioObjectPropertyElementMain,
                                    &current) && isfinite(current)) {
            current = clampedVolume(current);
            Float32 next = idv_audio_next_volume(current, increase, fine);
            if (writeFloatOutputProperty(device,
                                         kAudioDevicePropertyVolumeScalar,
                                         kAudioObjectPropertyElementMain,
                                         next)) {
                if (!clearMuteIfNeeded(device))
                    fprintf(stderr, "IdentityV audio key volume changed but mute state could not be cleared\n");
                return YES;
            }
        }
    }

    AudioObjectPropertyElement elements[IDVAudioMaxOutputChannels];
    UInt32 count = writableOutputChannels(device,
                                          kAudioDevicePropertyVolumeScalar,
                                          elements,
                                          IDVAudioMaxOutputChannels);
    if (count == 0) return NO;

    Float32 current[IDVAudioMaxOutputChannels];
    BOOL readable[IDVAudioMaxOutputChannels] = {0};
    for (UInt32 index = 0; index < count; index++) {
        if (readFloatOutputProperty(device,
                                    kAudioDevicePropertyVolumeScalar,
                                    elements[index],
                                    &current[index]) &&
            isfinite(current[index])) {
            current[index] = clampedVolume(current[index]);
            readable[index] = YES;
        }
    }

    BOOL wrote = NO;
    for (UInt32 index = 0; index < count; index++) {
        if (!readable[index]) continue;
        Float32 next = idv_audio_next_volume(current[index], increase, fine);
        if (writeFloatOutputProperty(device,
                                     kAudioDevicePropertyVolumeScalar,
                                     elements[index],
                                     next))
            wrote = YES;
    }
    if (wrote && !clearMuteIfNeeded(device))
        fprintf(stderr, "IdentityV audio key volume changed but mute state could not be cleared\n");
    return wrote;
}

static void enqueueAudioAction(IDVAudioKeyAction action, BOOL fine)
{
    dispatch_async(audioActionQueue(), ^{
        @autoreleasepool {
            AudioDeviceID device = kAudioObjectUnknown;
            if (!defaultOutputDevice(&device)) {
                fprintf(stderr, "IdentityV audio key action skipped: no default output device\n");
                atomic_store_explicit(&audioCapabilityMask, 0, memory_order_release);
                scheduleAudioCapabilityProbe();
                return;
            }

            BOOL success = NO;
            switch (action) {
                case IDVAudioKeyActionMute:
                    success = performMute(device);
                    break;
                case IDVAudioKeyActionVolumeDown:
                    success = performVolume(device, NO, fine);
                    break;
                case IDVAudioKeyActionVolumeUp:
                    success = performVolume(device, YES, fine);
                    break;
                case IDVAudioKeyActionNone:
                    return;
            }
            if (!success) {
                fprintf(stderr, "IdentityV audio key action skipped: output control unavailable (action=%d)\n", action);
                uint32_t bit = capabilityBitForAction(action);
                if (bit != 0)
                    atomic_fetch_and_explicit(&audioCapabilityMask, ~bit, memory_order_acq_rel);
                scheduleAudioCapabilityProbe();
            } else {
                refreshAudioCapabilities();
            }
        }
    });
}

static BOOL isIdentityVWineProcess(void)
{
    for (NSString *argument in NSProcessInfo.processInfo.arguments) {
        if ([argument rangeOfString:@"dwrg.exe" options:NSCaseInsensitiveSearch].location != NSNotFound)
            return YES;
    }

    return NO;
}

/*
 * The HID lease maps physical F11 to the otherwise-unused F20 usage so the
 * Dock cannot consume it first. UserKeyMapping has no modifier predicate, so
 * modified F11 chords arrive here as F20 and must be restored before Wine sees
 * them. CGEvent copying preserves the original type, timestamp, location,
 * flags, repeat state, and down/up direction; only the virtual key code moves
 * back to kVK_F11. If AppKit cannot make that lossless copy, consume the event
 * and report the failure instead of silently changing Command+F11 semantics.
 */
static NSEvent *eventRestoringF11(NSEvent *event)
{
    CGEventRef source = event.CGEvent;
    if (!source) return nil;
    CGEventRef copy = CGEventCreateCopy(source);
    if (!copy) return nil;
    CGEventSetIntegerValueField(copy, kCGKeyboardEventKeycode, kVK_F11);
    NSEvent *restored = [NSEvent eventWithCGEvent:copy];
    CFRelease(copy);
    return restored;
}

__attribute__((constructor))
static void installCommandGraveForwarder(void)
{
    @autoreleasepool
    {
        if (!isIdentityVWineProcess()) return;

        /* CoreAudio listener registration and the initial capability probe stay off AppKit's thread. */
        scheduleAudioCapabilityProbe();

        dispatch_async(dispatch_get_main_queue(), ^{
            NSEventMask mask = NSEventMaskKeyDown | NSEventMaskKeyUp;

            commandGraveMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask
                                                                        handler:^NSEvent *(NSEvent *event) {
                BOOL keyDown = event.type == NSEventTypeKeyDown;
                BOOL keyUp = event.type == NSEventTypeKeyUp;
                if (keyDown || keyUp) {
                    NSEventModifierFlags disallowed = NSEventModifierFlagCommand |
                                                       NSEventModifierFlagControl |
                                                       NSEventModifierFlagOption;
                    BOOL hasDisallowedModifier = (event.modifierFlags & disallowed) != 0;
                    IDVAudioKeyState previousState = audioKeyState;
                    IDVAudioKeyRoute route = idv_audio_key_route((uint16_t)event.keyCode,
                                                                 keyDown,
                                                                 event.isARepeat,
                                                                 hasDisallowedModifier,
                                                                 &audioKeyState);
                    if (route.restoreAsF11) {
                        NSEvent *restored = eventRestoringF11(event);
                        if (restored) return restored;
                        fprintf(stderr, "IdentityV F11 HID restore unavailable; consumed mapped event\n");
                        return nil;
                    }
                    if (route.consume) {
                        if (route.action != IDVAudioKeyActionNone) {
                            /* The main thread reads only an atomic cache; probing stays on audioActionQueue. */
                            if (!cachedAudioActionAvailable(route.action)) {
                                scheduleAudioCapabilityProbe();
                                if (!idv_audio_key_is_owned((uint16_t)event.keyCode, &previousState)) {
                                    idv_audio_key_reject_ownership((uint16_t)event.keyCode, &audioKeyState);
                                    if (event.keyCode == IDVAudioKeyCodeF20 &&
                                        idv_audio_key_is_forwarded_as_f11(IDVAudioKeyCodeF20, &audioKeyState)) {
                                        NSEvent *restored = eventRestoringF11(event);
                                        if (restored) return restored;
                                        fprintf(stderr, "IdentityV F11 HID restore unavailable; consumed mapped event\n");
                                        return nil;
                                    }
                                    return event;
                                }
                                /* We already consumed the original down; consume repeats while probing. */
                                return nil;
                            }
                            BOOL fine = (event.modifierFlags & NSEventModifierFlagShift) != 0;
                            enqueueAudioAction(route.action, fine);
                        }
                        return nil;
                    }
                }

                if (event.keyCode != kVK_ANSI_Grave ||
                    !(event.modifierFlags & NSEventModifierFlagCommand))
                    return event;

                NSWindow *window = event.window ?: NSApp.keyWindow;
                if (!window) return event;

                [window sendEvent:event];
                return nil;
            }];

            fprintf(stderr, "IdentityV Command+grave forwarder active\n");
        });
    }
}
