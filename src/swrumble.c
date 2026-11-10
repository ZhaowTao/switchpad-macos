// swrumble.c — the encoder, and nothing else.
#include "swrumble.h"
#include <math.h>
#include <string.h>

// The 101 amplitudes both bands are measured at, in the units SDL's own 0..65535 already uses (SDL_hidapi_switch.c). The
// codes are not stored: the high band's is two per step, the low band's starts at 0x40 and takes one step per two
// amplitudes with its ninth bit set on the odd ones, which is what these 101 rows come to. The last carries code 0x72.
static const uint16_t k_amp[101] = {
      0,  514,  775,  921, 1096, 1303, 1550, 1843, 2192, 2606,
   3100, 3686, 4383, 5213, 6199, 7372, 7698, 8039, 8395, 8767,
   9155, 9560, 9984, 10426, 10887, 11369, 11873, 12398, 12947, 13520,
   14119, 14744, 15067, 15397, 15734, 16079, 16431, 16790, 17158, 17534,
   17918, 18310, 18711, 19121, 19540, 19967, 20405, 20851, 21308, 21775,
   22251, 22739, 23236, 23745, 24265, 24797, 25340, 25894, 26462, 27041,
   27633, 28238, 28856, 29488, 30134, 30794, 31468, 32157, 32861, 33581,
   34316, 35068, 35836, 36620, 37422, 38242, 39079, 39935, 40809, 41703,
   42616, 43549, 44503, 45477, 46473, 47491, 48531, 49593, 50679, 51789,
   52923, 54082, 55266, 56476, 57713, 58977, 60268, 61588, 62936, 64315,
   65535
};

int swr_amplitude_step(uint16_t amplitude) {
    for (int i = 0; i < 101; i++) if (amplitude <= k_amp[i]) return i;
    return 100;
}

int swr_frequency_code(float hz, float lowest, float highest) {
    if (!isfinite(hz) || hz < lowest) hz = lowest;
    else if (hz > highest) hz = highest;
    return (int)lrintf(log2f(hz / SWR_FREQ_REF) * 32.0f);
}

unsigned swr_frequency_mix(float hz, float lowest, float highest, float blend) {
    // A frequency of 0 is clamped to the band's lowest, as the console's own encoder clamps anything out of range. It is
    // not read as "the game gave no frequency" on purpose: the encoder was verified on hardware with that behaviour, and a
    // caller that wants SWR_CODE_REF passes 150.0f, which is one line and no change to what has been felt.
    if (!(blend > 0)) return SWR_CODE_REF;
    int game = swr_frequency_code(hz, lowest, highest);
    if (blend >= 1) return (unsigned)game;
    long c = lrintf((float)SWR_CODE_REF + ((float)game - (float)SWR_CODE_REF) * blend);
    return c < 0x01 ? 0x01u : (unsigned)c;
}

unsigned swr_high_field(unsigned code) {
    int hf = ((int)code - 0x20) * 4;   // four a step from 0x04 at 80 Hz to 0x1FC at 1252 Hz
    return hf < 0x04 ? 0x04u : (unsigned)hf;
}

float swr_shape(float amplitude, float gain, float gamma) {
    if (!isfinite(amplitude) || amplitude <= 0) return 0;
    if (!isfinite(gain) || gain <= 0) return 0;
    if (!isfinite(gamma) || gamma <= 0) gamma = 1.0f;
    float a = amplitude > 1.0f ? 1.0f : amplitude;
    float s = powf(a, gamma) * gain;
    return s > 1.0f ? 1.0f : (s < 0 ? 0 : s);
}

void swr_encode(uint8_t out[4], const swr_value *v, float gain, float gamma, float blend) {
    if (!out) return;
    if (!v) { out[0] = 0x00; out[1] = 0x01; out[2] = 0x40; out[3] = 0x40; return; }
    float lo = swr_shape(v->amplitude_low, gain, gamma);
    float hi = swr_shape(v->amplitude_high, gain, gamma);
    if (lo <= 0 && hi <= 0) { out[0] = 0x00; out[1] = 0x01; out[2] = 0x40; out[3] = 0x40; return; }

    int hs = swr_amplitude_step((uint16_t)lrintf(hi * 65535.0f));
    int ls = swr_amplitude_step((uint16_t)lrintf(lo * 65535.0f));
    unsigned hf_amp = (unsigned)(2 * hs);                                             // the high band's code, one byte
    unsigned lf_amp = ls == 100 ? 0x0072u
                                : (unsigned)(0x0040 + ls / 2) | (ls % 2 ? 0x8000u : 0);   // the low band's, nine bits
    unsigned hf = swr_high_field(swr_frequency_mix(v->frequency_high, SWR_FREQ_HF_LOW, SWR_FREQ_HF_HIGH, blend));
    unsigned lf = swr_frequency_mix(v->frequency_low, SWR_FREQ_LF_LOW, SWR_FREQ_LF_HIGH, blend);

    out[0] = (uint8_t)(hf & 0xff);                        // the high band's frequency
    out[1] = (uint8_t)(hf_amp | ((hf >> 8) & 0x01));      // its amplitude, and the frequency's ninth bit
    out[2] = (uint8_t)(lf | ((lf_amp >> 8) & 0x80));      // the low band's frequency, and the amplitude's ninth bit
    out[3] = (uint8_t)(lf_amp & 0xff);
}

size_t swr_report_pro(uint8_t *out, size_t cap, uint8_t counter,
                      const uint8_t left[4], const uint8_t right[4],
                      uint8_t subcmd, const uint8_t *subdata, size_t sublen) {
    static const uint8_t neutral[4] = SWR_NEUTRAL;
    if (!out) return 0;
    // Over Bluetooth a Pro Controller's 0x01 is 49 bytes and over USB 64. 49 fits both: a USB frame is padded by the
    // transport, and a Bluetooth frame shorter than 49 is dropped by the firmware.
    const size_t total = 49;
    if (cap < total) return 0;
    memset(out, 0, total);
    out[0] = 0x01;
    out[1] = (uint8_t)(counter & 0x0f);
    memcpy(out + 2, left ? left : neutral, 4);
    memcpy(out + 6, right ? right : neutral, 4);
    if (subcmd) {
        out[10] = subcmd;
        size_t n = sublen > total - 11 ? total - 11 : sublen;
        if (subdata && n) memcpy(out + 11, subdata, n);
    }
    return total;
}

size_t swr_report_joycon(uint8_t *out, size_t cap, uint8_t counter,
                         const uint8_t side[4], uint8_t subcmd, const uint8_t *subdata, size_t sublen) {
    static const uint8_t neutral[4] = SWR_NEUTRAL;
    if (!out) return 0;
    const size_t total = 49;
    if (cap < total) return 0;
    memset(out, 0, total);
    out[0] = 0x30;
    out[1] = (uint8_t)(counter & 0x0f);
    // A Joy-Con's report 0x30 carries eight rumble bytes, one four-byte group per half of the pair. A single pad sends
    // its own group in the first four and the neutral in the last four.
    memcpy(out + 2, side ? side : neutral, 4);
    memcpy(out + 6, neutral, 4);
    if (subcmd) {
        out[10] = subcmd;
        size_t n = sublen > total - 11 ? total - 11 : sublen;
        if (subdata && n) memcpy(out + 11, subdata, n);
    }
    return total;
}
