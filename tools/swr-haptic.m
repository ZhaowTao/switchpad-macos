// swr-haptic — play a rumble on a Switch pad from the command line.
//
//   swr-haptic list
//   swr-haptic play --amp 0.8 --freq 320 --ms 400
//   swr-haptic sweep                 # 80 Hz to 1252 Hz: the texture changes, which is what the frequency codes buy
//   swr-haptic curve                 # the same hit flat, then shaped, so a game's 0.06 can be felt
//   swr-haptic tune                  # a melody: the frequency is the pitch, so the pad plays it on a table
//
// It is also the check that switchpad-macos rests on: a Pro Controller whose input GameController owns can still be
// opened as an IOHIDDevice and written to, so output report 0x01 reaches it and the encoder drives it directly.
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hid/IOHIDLib.h>
#include <math.h>
#include <string.h>
#include "swrumble.h"

#define NINTENDO_VID 0x057E
#define PRO_PID      0x2009
#define JOYCON_L_PID 0x2006
#define JOYCON_R_PID 0x2007
#define SNES_PID     0x2017
#define N64_PID      0x2019

static long prop_int(IOHIDDeviceRef d, CFStringRef k) {
    CFTypeRef v = IOHIDDeviceGetProperty(d, k);
    if (!v || CFGetTypeID(v) != CFNumberGetTypeID()) return -1;
    long n = -1;
    CFNumberGetValue(v, kCFNumberLongType, &n);
    return n;
}
static NSString *prop_str(IOHIDDeviceRef d, CFStringRef k) {
    CFTypeRef v = IOHIDDeviceGetProperty(d, k);
    return (v && CFGetTypeID(v) == CFStringGetTypeID()) ? CFBridgingRelease(CFRetain(v)) : @"?";
}

// The pads this understands: a Pro Controller over report 0x01, a Joy-Con over 0x30. Others are listed and skipped, with
// the reason, rather than silently ignored.
static const char *kind_of(long pid) {
    switch (pid) {
        case PRO_PID:     return "pro";
        case JOYCON_L_PID: return "joycon-left";
        case JOYCON_R_PID: return "joycon-right";
        case SNES_PID:    return "snes (no rumble)";
        case N64_PID:     return "n64 (no rumble)";
        default:          return "unknown";
    }
}
static int has_rumble(long pid) { return pid == PRO_PID || pid == JOYCON_L_PID || pid == JOYCON_R_PID; }

typedef struct { IOHIDDeviceRef dev; long pid; char name[64]; } pad;

static int find_pads(pad *out, int max) {
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    IOHIDManagerSetDeviceMatching(mgr, NULL);
    IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    CFSetRef set = IOHIDManagerCopyDevices(mgr);
    int n = 0;
    if (!set) return 0;
    CFIndex count = CFSetGetCount(set);
    IOHIDDeviceRef *all = calloc((size_t)count, sizeof *all);
    CFSetGetValues(set, (const void **)all);
    for (CFIndex i = 0; i < count && n < max; i++) {
        if (prop_int(all[i], CFSTR(kIOHIDVendorIDKey)) != NINTENDO_VID) continue;
        out[n].dev = (IOHIDDeviceRef)CFRetain(all[i]);
        out[n].pid = prop_int(all[i], CFSTR(kIOHIDProductIDKey));
        snprintf(out[n].name, sizeof out[n].name, "%s", prop_str(all[i], CFSTR(kIOHIDProductKey)).UTF8String);
        n++;
    }
    free(all);
    CFRelease(set);
    // The manager is left open on purpose: closing it would release the devices it handed out.
    return n;
}

// One frame. counter must advance or the pad drops the report as a duplicate; the rumble bytes carry nothing else.
static void write_frame(IOHIDDeviceRef dev, long pid, const uint8_t left[4], const uint8_t right[4],
                        uint8_t *counter, uint8_t subcmd, const uint8_t *sub, size_t sublen) {
    uint8_t rep[64];
    size_t n = pid == PRO_PID
        ? swr_report_pro(rep, sizeof rep, (*counter)++, left, right, subcmd, sub, sublen)
        : swr_report_joycon(rep, sizeof rep, (*counter)++, left, subcmd, sub, sublen);
    if (n) IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, pid == PRO_PID ? 0x01 : 0x30, rep, (CFIndex)n);
}

// Play one value for a while. The pad holds the last frame it was given, but a game re-sends every frame and a link that
// drops one should not go silent, so this re-sends at the rate a game would.
static void play(IOHIDDeviceRef dev, long pid, const swr_value *v, float gain, float gamma, int ms) {
    static uint8_t counter;   // across calls: a melody re-sends a frame every 10 ms and the counter must keep moving
    uint8_t l[4], r[4], s[4];
    swr_encode(l, v, gain, gamma, 1);
    // A Pro Controller drives two grips, a single Joy-Con one actuator: it takes the first four bytes of report 0x30 and
    // the second group stays neutral, which swr_report_joycon already does. So both paths start from the same encode.
    memcpy(r, l, 4);
    swr_encode(s, NULL, 1, 1, 1);
    for (int t = 0; t < ms; t += 10) {
        write_frame(dev, pid, l, r, &counter, 0, NULL, 0);
        usleep(10000);
    }
    write_frame(dev, pid, s, s, &counter, 0, NULL, 0);
}

static int open_pad(pad *p) {
    IOReturn r = IOHIDDeviceOpen(p->dev, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) {
        fprintf(stderr, "cannot open %s: 0x%08x\n", p->name, r);
        return 0;
    }
    // Firmware stays mute until told otherwise, over Bluetooth on both a Joy-Con and a Pro Controller.
    uint8_t counter = 0, neutral[4] = SWR_NEUTRAL;
    uint8_t on = 0x01;
    write_frame(p->dev, p->pid, neutral, neutral, &counter, SWR_SUBCMD_ENABLE_VIBRATION, &on, 1);
    usleep(200000);
    return 1;
}

// A melody is a list of frequencies. The actuator has one degree of freedom and the frequency code is the pitch, so a note
// is a frequency and a duration; resting the pad on a table turns it into something heard rather than only felt, because the
// table is the sounding board. The bands' own ranges (41..626 Hz and 81.75..1252 Hz) cover most of five octaves, but only
// C4 to C6 is used here: below that an LRA swings too slowly to be a note, above it the steps grow coarser.
static int note_semitone(char c) {
    switch (c) {
        case 'C': case 'c': return 0;
        case 'D': case 'd': return 2;
        case 'E': case 'e': return 4;
        case 'F': case 'f': return 5;
        case 'G': case 'g': return 7;
        case 'A': case 'a': return 9;
        case 'B': case 'b': return 11;
    }
    return -1;
}
static int note_midi(const char *s) {   // "C4", "F#3", "Bb5" -> MIDI (C4 60, A4 69), -1 if it is not a note
    if (!s || !*s) return -1;
    int st = note_semitone(*s);
    if (st < 0) return -1;
    s++;
    if (*s == '#') { st++; s++; }
    else if (*s == 'b' && s[1] >= '0' && s[1] <= '9') { st--; s++; }
    int oct = 4;
    if (*s >= '0' && *s <= '9') { oct = *s - '0'; s++; }
    if (*s || oct < 0 || oct > 8) return -1;
    return (oct + 1) * 12 + st;
}
static float midi_hz(int n) { return 440.0f * powf(2.0f, (float)(n - 69) / 12.0f); }

// Public domain, and long enough to be recognisable: the first two phrases of Beethoven's Ode to Joy.
static const char *k_ode_to_joy =
    "E4 F4 G4 G4 F4 E4 D4 C4 C4 D4 E4 E4:400 D4:200 D4:400 "
    "E4 F4 G4 G4 F4 E4 D4 C4 C4 D4 E4 D4:400 C4:200 C4:600";

// A note is held for its own length and the next follows with no gap: an actuator with mass takes a few milliseconds to
// swing to a new frequency, which is what makes consecutive notes run together as a phrase instead of separate buzzes.
static int play_tune(pad *p, const char *spec) {
    char buf[512];
    snprintf(buf, sizeof buf, "%s", spec);
    int played = 0;
    for (char *tok = strtok(buf, " ,"); tok; tok = strtok(NULL, " ,")) {
        int ms = 250;
        char *colon = strchr(tok, ':');
        if (colon) { *colon = 0; ms = atoi(colon + 1); if (ms <= 0) ms = 250; }
        int m = note_midi(tok);
        if (m < 0) { fprintf(stderr, "  not a note: %s\n", tok); continue; }
        float hz = midi_hz(m);
        // The high band carries the pitch; the low band sits at 150 Hz for body, so every note keeps the same weight and
        // only the pitch moves, which is what makes a melody out of it.
        swr_value v = {0.22f, 0.85f, 150.0f, hz};
        printf("  %-3s %7.1f Hz  %3d ms\n", tok, hz, ms);
        play(p->dev, p->pid, &v, 1, 1, ms);
        played++;
    }
    return played;
}

static void usage(FILE *f) {
    fprintf(f,
        "swr-haptic — HD rumble on a Nintendo Switch pad\n\n"
        "  swr-haptic list\n"
        "  swr-haptic play [--amp 0..1] [--freq Hz] [--ms n] [--gain x] [--gamma x] [--device i]\n"
        "  swr-haptic sweep [--ms n] [--device i]\n"
        "  swr-haptic curve [--device i]\n"
        "  swr-haptic tune [\"C4:250 D4:250 E4:500\"] [--device i]\n\n"
        "  --amp    strength, 0..1 (default 0.8)\n"
        "  --freq   high-band frequency in Hz, 81.75..1252.57 (default 320)\n"
        "  --ms     how long, in milliseconds (default 400)\n"
        "  --gain   strength multiplier (default 1)\n"
        "  --gamma  strength curve, below 1 lifts quiet hits (default 1)\n\n"
        "Rest the pad on a table for tune: the table is the sounding board.\n");
}

int main(int argc, char **argv) {
    @autoreleasepool {
        pad pads[8];
        int n = find_pads(pads, 8);
        if (!n) { fprintf(stderr, "no Nintendo pad is connected\n"); return 2; }

        const char *cmd = argc > 1 ? argv[1] : "list";
        if (!strcmp(cmd, "-h") || !strcmp(cmd, "--help")) { usage(stdout); return 0; }

        if (!strcmp(cmd, "list")) {
            for (int i = 0; i < n; i++)
                printf("%d  %-22s pid=0x%04lX  %-13s %s\n", i, pads[i].name, pads[i].pid,
                       kind_of(pads[i].pid), has_rumble(pads[i].pid) ? "" : "(skipped)");
            return 0;
        }

        float amp = 0.8f, freq = 320.0f, gain = 1.0f, gamma = 1.0f;
        int ms = 400, want = -1;
        const char *melody = NULL;
        int first = 2;
        // tune takes the melody as a bare argument, so its flags start after it
        if (!strcmp(cmd, "tune") && argc > 2 && argv[2][0] != '-') { melody = argv[2]; first = 3; }
        for (int i = first; i < argc; i++) {
            int has = i + 1 < argc;
            if (!strcmp(argv[i], "--amp") && has) amp = (float)atof(argv[++i]);
            else if (!strcmp(argv[i], "--freq") && has) freq = (float)atof(argv[++i]);
            else if (!strcmp(argv[i], "--ms") && has) ms = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--gain") && has) gain = (float)atof(argv[++i]);
            else if (!strcmp(argv[i], "--gamma") && has) gamma = (float)atof(argv[++i]);
            else if (!strcmp(argv[i], "--device") && has) want = atoi(argv[++i]);
            else { fprintf(stderr, "unknown argument: %s\n", argv[i]); usage(stderr); return 1; }
        }

        pad *p = NULL;
        if (want >= 0 && want < n) p = &pads[want];
        else for (int i = 0; i < n; i++) if (has_rumble(pads[i].pid)) { p = &pads[i]; break; }
        if (!p) { fprintf(stderr, "no pad with rumble: try 'swr-haptic list'\n"); return 3; }
        if (!open_pad(p)) return 4;

        if (!strcmp(cmd, "play")) {
            swr_value v = {amp, amp, freq, freq};
            printf("%s: amp %.2f, %.0f Hz, %d ms, gain %.2f, gamma %.2f\n", p->name, amp, freq, ms, gain, gamma);
            play(p->dev, p->pid, &v, gain, gamma, ms);
        } else if (!strcmp(cmd, "sweep")) {
            // The low band carries 41..626 Hz and the high band 81.75..1252 Hz, but only the high band is swept here: it is
            // the one whose code moves in steps a hand can tell apart on a Pro Controller.
            static const float hz[] = {90, 120, 160, 200, 260, 320, 420, 520, 640, 800, 1000, 1252};
            printf("sweeping the high band; the texture should sharpen as it climbs\n");
            for (unsigned i = 0; i < sizeof hz / sizeof *hz; i++) {
                swr_value v = {0.0f, 0.85f, 150.0f, hz[i]};
                printf("  %.0f Hz\n", hz[i]);
                play(p->dev, p->pid, &v, 1, 1, ms > 0 ? ms : 220);
            }
        } else if (!strcmp(cmd, "curve")) {
            // What #2148 measured: a game tuned for the console's actuator gives 0.06, which a linear gain leaves as a
            // 0.18 whisper. The same value, flat then shaped, is the whole argument for the strength curve.
            swr_value quiet = {0.06f, 0.06f, 150.0f, 320.0f};
            printf("the same hit at 0.06: flat (gain 3, gamma 1), then shaped (gain 3, gamma 0.5)\n");
            play(p->dev, p->pid, &quiet, 3, 1.0f, 500);
            usleep(400000);
            play(p->dev, p->pid, &quiet, 3, 0.5f, 500);
        } else if (!strcmp(cmd, "tune")) {
            const char *spec = melody ? melody : k_ode_to_joy;
            printf("%s: %s\n", p->name, melody ? "custom melody" : "Ode to Joy, the first two phrases");
            int notes = play_tune(p, spec);
            printf("%d notes\n", notes);
        } else {
            fprintf(stderr, "unknown command: %s\n", cmd);
            usage(stderr);
            return 1;
        }
        return 0;
    }
}
