#ifndef IDV_REBINDER_ALIAS_TRANSLATE_H
#define IDV_REBINDER_ALIAS_TRANSLATE_H

#include <CoreAudio/CoreAudio.h>
#include "rebinder_filter_protocol.h"

typedef OSStatus (*idv_alias_get_data_fn)(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *, void *);

int idv_alias_translate_matches(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *, void *);
OSStatus idv_alias_translate(idv_rebinder_filter_state_t *, idv_alias_get_data_fn, UInt32 *, void *);

#endif
