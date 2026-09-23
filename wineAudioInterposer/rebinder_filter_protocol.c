#include "rebinder_filter_protocol.h"
void idv_reset(idv_rebinder_filter_state_t*s){s->state=IDV_IDLE;s->device=0;}
int idv_note_default(idv_rebinder_filter_state_t*s,uint32_t d,uint32_t u){idv_reset(s);if(d==u)return 0;s->device=d;s->state=IDV_EXPECT_SIZE;return 1;}
int idv_note_size(idv_rebinder_filter_state_t*s){if(s->state!=IDV_EXPECT_SIZE){idv_reset(s);return 0;}s->state=IDV_EXPECT_DATA;return 1;}
int idv_note_default_failure(idv_rebinder_filter_state_t*s){idv_reset(s);s->state=IDV_EXPECT_SIZE_FAIL;return 1;}
int idv_take_data(idv_rebinder_filter_state_t*s,uint32_t*d){if(s->state!=IDV_EXPECT_DATA){idv_reset(s);return 0;}*d=s->device;idv_reset(s);return 1;}
int idv_take_alias_data(idv_rebinder_filter_state_t*s,uint32_t*d){if(s->state!=IDV_EXPECT_DATA){idv_reset(s);return 0;}*d=s->device;s->state=IDV_EXPECT_STREAM_SIZE;return 1;}
int idv_alias_accept(idv_rebinder_filter_state_t*s,uint32_t d,idv_alias_event_t e){idv_rebinder_state_t want=(idv_rebinder_state_t)(IDV_EXPECT_STREAM_SIZE+e);if(s->device!=d||s->state!=want){idv_reset(s);return 0;}if(e==IDV_ALIAS_UID)idv_reset(s);else s->state=(idv_rebinder_state_t)(want+1);return 1;}
