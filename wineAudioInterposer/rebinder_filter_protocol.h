#ifndef IDV_REBINDER_FILTER_PROTOCOL_H
#define IDV_REBINDER_FILTER_PROTOCOL_H
#include <stdint.h>
typedef enum { IDV_IDLE, IDV_EXPECT_SIZE, IDV_EXPECT_DATA, IDV_EXPECT_STREAM_SIZE, IDV_EXPECT_STREAM_DATA, IDV_EXPECT_NAME, IDV_EXPECT_UID, IDV_EXPECT_SIZE_FAIL } idv_rebinder_state_t;
typedef struct { idv_rebinder_state_t state; uint32_t device; } idv_rebinder_filter_state_t;
typedef enum { IDV_ALIAS_STREAM_SIZE, IDV_ALIAS_STREAM_DATA, IDV_ALIAS_NAME, IDV_ALIAS_UID } idv_alias_event_t;
int idv_note_default(idv_rebinder_filter_state_t *, uint32_t, uint32_t); int idv_note_size(idv_rebinder_filter_state_t *); int idv_note_default_failure(idv_rebinder_filter_state_t *); int idv_take_data(idv_rebinder_filter_state_t *, uint32_t *); int idv_take_alias_data(idv_rebinder_filter_state_t *, uint32_t *); int idv_alias_accept(idv_rebinder_filter_state_t *, uint32_t, idv_alias_event_t); void idv_reset(idv_rebinder_filter_state_t *);
#endif
