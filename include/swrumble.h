// swrumble.h — a Nintendo Switch pad's HD rumble, as the four bytes an output report carries for one actuator.
//
// What this is. A Joy-Con and a Pro Controller each take, per actuator, four bytes: a high-band frequency, a high-band
// amplitude, a low-band frequency and a low-band amplitude. The frequency field is a code, not a value: thirty-two codes
// to an octave from 40 Hz, so 160 Hz is 0x40 and 320 Hz is 0x60. The amplitude field is a step up a 101-entry table the
// actuator was measured at. Send both bands and the actuator plays their sum, which is why a punch's click (high band)
// and a block's thud (low band) can be told apart by feel and not only by strength.
//
// Where the numbers come from. SDL's SDL_hidapi_switch.c holds the amplitude table and the packing; dekuNukem's
// Nintendo_Switch_Reverse_Engineering holds the frequency rows the codes were measured at. Both are reproduced here, and
// neither is required to build this: there are no dependencies.
//
// Why it exists. On macOS, GameController gives a Switch pad a haptics route that degrades in three steps (see
// docs/pro-controller.md): no advanced player on macOS 26+, so one plain player whose left and right engines overwrite
// each other, so a single merged handle, driven by 0.5 s pulses with a 0.15 s lead. The result changes in strength but not
// in texture. Writing the pad's own output report skips all three.
//
// What it is not. It does not open a device, read input, pace reports, or know about a game. Those are the caller's HID
// layer's job, and getting the pacing wrong is enough to break a pad: see docs/pro-controller.md. A game's own vibration
// values are its own.
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// The bands a pad drives, and the range each takes a frequency in. The table's rows: the low band's codes run 0x01..0x7F
// and span 41..626 Hz, the high band's 0x21..0x9F and span 81.75..1252 Hz. A frequency outside a band's range holds at the
// end, as the console's own encoder does.
#define SWR_FREQ_LF_LOW   41.0f
#define SWR_FREQ_LF_HIGH  626.29f
#define SWR_FREQ_HF_LOW   81.75f
#define SWR_FREQ_HF_HIGH  1252.57f

// The frequency SDL drives both bands at when it has no better idea: code 0x3D, about 150 Hz, where these actuators are
// loudest. It is also the code a blend of 0 falls back to.
#define SWR_FREQ_REF      40.0f
#define SWR_CODE_REF      0x3Du

// The actuator at rest. Not the low band's zero code (0x00 0x40): a Joy-Con's firmware reads that as the start of a
// subcommand in a report that carries one, which silences the pad until the next frame.
#define SWR_NEUTRAL {0x00, 0x01, 0x40, 0x40}

// One vibration value, as a game gives it: two bands, each with a strength and a frequency. Amplitude is 0..1, frequency
// in Hz. A game that only sends strength leaves a frequency at 0, which swr_encode reads as "use SWR_CODE_REF".
typedef struct {
    float amplitude_low;
    float amplitude_high;
    float frequency_low;
    float frequency_high;
} swr_value;

// How the four bytes are built, in the open, because a caller may want to log or test each step.
int      swr_amplitude_step(uint16_t amplitude);                  // 0..100, the table row a 0..65535 amplitude lands on
int      swr_frequency_code(float hz, float lowest, float highest);  // the table's code for a frequency
unsigned swr_frequency_mix(float hz, float lowest, float highest, float blend);  // the code to drive, blended toward SWR_CODE_REF
unsigned swr_high_field(unsigned code);                           // the high band's frequency field, 0x04..0x1FC

// A strength curve, for the reason #2148 found: a game tuned for the console's own actuator sends very little (The Legend
// of Zelda: Ocarina of Time peaks at 0.06), and a linear gain either stays too soft or clips the strong hits. gamma below 1
// lifts the weak end without touching 1.0, gamma above 1 pushes it down. gain is applied on the curved value.
//   swr_shape(0.06, 3.0, 0.5) = 0.73   a quiet hit becomes a felt one
//   swr_shape(1.00, 3.0, 0.5) = 1.00   a loud hit is not clipped twice
float swr_shape(float amplitude, float gain, float gamma);

// The four bytes one actuator takes. blend 1 drives each band at the game's own frequency, 0 at SWR_CODE_REF, and a value
// between mixes them in code space, which is one octave scale either way. Both amplitudes zero yields SWR_NEUTRAL.
void swr_encode(uint8_t out[4], const swr_value *v, float gain, float gamma, float blend);

// An output report 0x01 body for a Pro Controller: report id, an incrementing counter (4 bits), left and right bytes,
// then an optional subcommand. len is 49 over Bluetooth and 64 over USB; a frame carrying only rumble still goes out at
// that length, because a short one is not what the pad's firmware answers. Returns the number of bytes written to out,
// 0 if cap is too small.
//
// Report 0x01 is "rumble and subcommand". Passing subcmd 0 gives a frame with an empty subcommand field: fine for a
// one-off subcommand such as 0x48, and fine for the short, bounded bursts this repository's CLI plays. It is NOT the
// right frame for a continuous rumble stream: 0x10 is "rumble only", carries an 8-byte body, and is what long-running
// integrations use. See docs/pro-controller.md for a measured failure of the 0x01-at-high-rate approach.
size_t swr_report_pro(uint8_t *out, size_t cap, uint8_t counter,
                      const uint8_t left[4], const uint8_t right[4],
                      uint8_t subcmd, const uint8_t *subdata, size_t sublen);

// The subcommand that lets the firmware answer rumble at all: 0x48 with one byte 0x01. A Joy-Con over Bluetooth starts
// muted and needs it; a Pro Controller is the same firmware family, and switch_hid.c sends it after opening either.
#define SWR_SUBCMD_ENABLE_VIBRATION 0x48

// A Joy-Con's own output report 0x30 body (report id, counter, eight rumble bytes, then the subcommand). Same rumble
// layout as a Pro Controller's 0x01; the difference is the report id and, on a Joy-Con, the two actuators being the pad's
// own halves rather than one pad's left and right grips.
size_t swr_report_joycon(uint8_t *out, size_t cap, uint8_t counter,
                        const uint8_t side[4], uint8_t subcmd, const uint8_t *subdata, size_t sublen);

#ifdef __cplusplus
}
#endif
