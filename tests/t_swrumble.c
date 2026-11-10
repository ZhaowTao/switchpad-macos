// t_swrumble.c — the encoder against dekuNukem's rumble_data_table.md and SDL's amplitude table, row by row.
//
// These are the same assertions the engine's own t_joycon_rumble.c makes, moved onto the standalone encoder, so the two
// cannot drift: the frequencies the codes round to, the high band's field, the four bytes one actuator takes, and the
// packing that keeps an amplitude's ninth bit out of a frequency. What is new here is the strength curve.
#include "swrumble.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static void bytes(uint8_t out[4], float amp_low, float freq_low, float amp_high, float freq_high, float blend) {
    swr_value v = {amp_low, amp_high, freq_low, freq_high};
    swr_encode(out, &v, 1, 1, blend);   // gain 1, gamma 1: the plain encoding
}
static int same(const uint8_t b[4], int b0, int b1, int b2, int b3) {
    return b[0] == b0 && b[1] == b1 && b[2] == b2 && b[3] == b3;
}

int main(void) {
    // Rows of the table: the low band's code for a frequency, thirty-two codes an octave from 40 Hz
    static const struct { float hz; int code; } rows[] = {
        {41, 0x01}, {47, 0x07}, {57, 0x10}, {80, 0x20}, {113, 0x30}, {149.93f, 0x3D},
        {160, 0x40}, {226, 0x50}, {320, 0x60}, {453, 0x70}, {626.29f, 0x7F}
    };
    for (unsigned i = 0; i < sizeof rows / sizeof rows[0]; i++)
        assert(swr_frequency_code(rows[i].hz, SWR_FREQ_LF_LOW, SWR_FREQ_LF_HIGH) == rows[i].code);

    // The high band carries on past the low band's last code: 640 Hz is 0x80, 1252 Hz 0x9F, its field 0x1FC
    assert(swr_frequency_code(640, SWR_FREQ_HF_LOW, SWR_FREQ_HF_HIGH) == 0x80);
    assert(swr_frequency_code(SWR_FREQ_HF_HIGH, SWR_FREQ_HF_LOW, SWR_FREQ_HF_HIGH) == 0x9F);
    assert(swr_high_field(0x9F) == 0x1FC);
    assert(swr_high_field(0x3D) == 0x74);   // SDL's high band
    assert(swr_high_field(0x21) == 0x04);   // the band's first step, 80 Hz

    // A frequency outside a band holds at its end, as the console's own encoder does
    assert(swr_frequency_code(20, SWR_FREQ_LF_LOW, SWR_FREQ_LF_HIGH) == 0x01);
    assert(swr_frequency_code(3000, SWR_FREQ_LF_LOW, SWR_FREQ_LF_HIGH) == 0x7F);
    assert(swr_frequency_code(3000, SWR_FREQ_HF_LOW, SWR_FREQ_HF_HIGH) == 0x9F);

    uint8_t b[4];
    // Idle: the neutral value an un-driven actuator needs
    bytes(b, 0, 160, 0, 320, 1);
    assert(same(b, 0x00, 0x01, 0x40, 0x40));

    // Full strength at the game's own 160 and 320 Hz, then at SDL's fixed pair
    bytes(b, 1, 160, 1, 320, 1);
    assert(same(b, 0x00, 0xC9, 0x40, 0x72));
    bytes(b, 1, 160, 1, 320, 0);
    assert(same(b, 0x74, 0xC8, 0x3D, 0x72));

    // A low band at 62 Hz with a high band past the low band's range at 1252 Hz
    bytes(b, 1, 62, 1, 1252, 1);
    assert(same(b, 0xFC, 0xC9, 0x14, 0x72));

    // A single band: the other's amplitude is zero and its field still carries its frequency
    bytes(b, 1, 160, 0, 320, 1);
    assert(same(b, 0x00, 0x01, 0x40, 0x72));

    // Throughout the amplitude table the bands' frequencies stay where they were put
    for (int step = 1; step <= 100; step++) {
        float a = (float)step / 100.0f;
        bytes(b, a, 160, a, 320, 1);
        assert((b[2] & 0x7F) == 0x40);   // 160 Hz's code, with the amplitude's ninth bit above it
        assert((b[1] & 0x01) == 0x01);   // 320 Hz's field is 0x100, whose ninth bit lands here
    }

    // A mix between the two sits between them, and the ends are the two fixed answers
    unsigned fixed = swr_frequency_mix(320, SWR_FREQ_LF_LOW, SWR_FREQ_LF_HIGH, 0);
    unsigned game = swr_frequency_mix(320, SWR_FREQ_LF_LOW, SWR_FREQ_LF_HIGH, 1);
    unsigned half = swr_frequency_mix(320, SWR_FREQ_LF_LOW, SWR_FREQ_LF_HIGH, 0.5f);
    assert(fixed == SWR_CODE_REF && game == 0x60 && half > fixed && half < game);

    // The strength curve: the reason it exists is a game that peaks at 0.06 on the console's own actuator
    assert(fabsf(swr_shape(1.0f, 1.0f, 1.0f) - 1.0f) < 1e-5f);
    assert(fabsf(swr_shape(0.06f, 1.0f, 1.0f) - 0.06f) < 1e-5f);
    float lifted = swr_shape(0.06f, 3.0f, 0.5f);
    assert(lifted > 0.7f && lifted < 0.76f);       // 0.245 * 3 = 0.735: audible where 0.18 was not
    assert(fabsf(swr_shape(1.0f, 3.0f, 0.5f) - 1.0f) < 1e-5f);   // and no second clip on a loud hit
    assert(swr_shape(0.06f, 3.0f, 2.0f) < swr_shape(0.06f, 3.0f, 1.0f));   // gamma above 1 pushes down
    assert(swr_shape(0.0f, 3.0f, 0.5f) == 0.0f);   // silence stays silent
    assert(swr_shape(NAN, 3.0f, 0.5f) == 0.0f);
    assert(swr_shape(0.5f, -1.0f, 1.0f) == 0.0f);

    // A curved value still encodes, and still yields the neutral bytes when it rounds to nothing
    swr_value quiet = {0.06f, 0.06f, 160.0f, 320.0f};
    uint8_t flat[4], curved[4];
    swr_encode(flat, &quiet, 1, 1, 1);
    swr_encode(curved, &quiet, 3, 0.5f, 1);
    assert(curved[3] > flat[3]);   // a stronger low band, so a higher amplitude code
    swr_value silent = {0, 0, 160, 320};
    swr_encode(flat, &silent, 1, 1, 1);
    assert(same(flat, 0x00, 0x01, 0x40, 0x40));

    // Report 0x01: the shape a Pro Controller takes over Bluetooth, and the subcommand that turns rumble on
    uint8_t left[4], right[4], rep[64];
    bytes(left, 1, 160, 1, 320, 1);
    bytes(right, 0.5f, 200, 0.5f, 400, 1);
    size_t n = swr_report_pro(rep, sizeof rep, 0x0a, left, right, 0, NULL, 0);
    assert(n == 49);
    assert(rep[0] == 0x01 && rep[1] == 0x0a);
    assert(!memcmp(rep + 2, left, 4) && !memcmp(rep + 6, right, 4));
    assert(rep[10] == 0 && rep[11] == 0);   // no subcommand: the tail is zero
    n = swr_report_pro(rep, sizeof rep, 0x0b, left, right, SWR_SUBCMD_ENABLE_VIBRATION, (const uint8_t[]){0x01}, 1);
    assert(n == 49 && rep[10] == 0x48 && rep[11] == 0x01);
    assert(swr_report_pro(rep, 16, 0, left, right, 0, NULL, 0) == 0);   // too small a buffer is refused, not truncated
    // A null side falls back to neutral rather than a zeroed actuator
    n = swr_report_pro(rep, sizeof rep, 0, NULL, right, 0, NULL, 0);
    assert(n == 49 && rep[2] == 0x00 && rep[3] == 0x01 && rep[4] == 0x40 && rep[5] == 0x40);

    // Report 0x30: the same layout one half of a Joy-Con pair takes
    n = swr_report_joycon(rep, sizeof rep, 0x03, left, SWR_SUBCMD_ENABLE_VIBRATION, (const uint8_t[]){0x01}, 1);
    assert(n == 49 && rep[0] == 0x30 && rep[1] == 0x03);
    assert(!memcmp(rep + 2, left, 4));
    assert(rep[6] == 0x00 && rep[7] == 0x01 && rep[8] == 0x40 && rep[9] == 0x40);   // the other half, neutral
    assert(rep[10] == 0x48 && rep[11] == 0x01);

    printf("t_swrumble: all assertions passed\n");
    return 0;
}
