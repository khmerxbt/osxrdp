/* SPDX-License-Identifier: Apache-2.0 */
#ifndef XRDP_DISPLAY_CONTROL_FRAGMENTS_H
#define XRDP_DISPLAY_CONTROL_FRAGMENTS_H
#include <string.h>
/* MS-RDPEDISP: 8-byte header, 8-byte layout prefix, at most 16 40-byte monitors. */
#define XRDP_DISPLAY_CONTROL_MAX_PDU (16 + 16 * 40)
struct xrdp_display_control_fragments
{
    unsigned char data[XRDP_DISPLAY_CONTROL_MAX_PDU];
    int expected;
    int used;
};
/* Returns -1 for invalid input, 0 while incomplete, 1 with a complete PDU.
 * The returned pointer remains valid until the next call. No allocation. */
static inline int
xrdp_display_control_feed(struct xrdp_display_control_fragments *state,
                          const char *data, int bytes, int total, int first,
                          const char **complete, int *complete_bytes)
{
    *complete = NULL;
    *complete_bytes = 0;
    if (data == NULL || bytes <= 0 || bytes > XRDP_DISPLAY_CONTROL_MAX_PDU)
        goto invalid;
    if (first)
    {
        if (state->expected != 0 || total < 8 || total > XRDP_DISPLAY_CONTROL_MAX_PDU || bytes > total)
            goto invalid;
        state->expected = total;
        state->used = 0;
    }
    if (state->expected == 0)
    {
        if (bytes < 8) goto invalid;
        *complete = data;
        *complete_bytes = bytes;
        return 1;
    }
    if (bytes > state->expected - state->used) goto invalid;
    memcpy(state->data + state->used, data, bytes);
    state->used += bytes;
    if (state->used != state->expected) return 0;
    *complete = (const char *)state->data;
    *complete_bytes = state->used;
    state->used = state->expected = 0;
    return 1;
invalid:
    state->used = state->expected = 0;
    return -1;
}
#endif
