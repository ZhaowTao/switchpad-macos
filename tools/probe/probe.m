// probe.m — Is a Switch Pro Controller's rumble reachable from the Mac?
//
// The question this answers, before any engine code changes: GameController keeps the pad's input path
// (gamecontrollerd owns it, and its haptics route is the three-step degradation documented in
// docs/pro-controller.md). Can a second holder still open the IOHIDDevice and write output report 0x01,
// the one that carries eight rumble bytes? If yes, an HD rumble encoder can drive the pad directly and
// skip Core Haptics entirely, which is the whole point of switchpad-macos.
//
// Read-only until the last stage: it enumerates, reads the report descriptor, and only then writes. Every
// write is a neutral or a short burst that ends back at neutral.

#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hid/IOHIDLib.h>

#define NINTENDO_VID 0x057E
#define PRO_PID      0x2009
#define JOYCON_L_PID 0x2006
#define JOYCON_R_PID 0x2007
#define SNES_PID     0x2017
#define N64_PID      0x2019

static NSString *transport_of(IOHIDDeviceRef d) {
    CFTypeRef t = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDTransportKey));
    return t ? CFBridgingRelease(CFRetain(t)) : @"?";
}
static long prop_int(IOHIDDeviceRef d, CFStringRef k) {
    CFTypeRef v = IOHIDDeviceGetProperty(d, k);
    if (!v) return -1;
    long n = -1;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongType, &n);
    return n;
}
static NSString *prop_str(IOHIDDeviceRef d, CFStringRef k) {
    CFTypeRef v = IOHIDDeviceGetProperty(d, k);
    return (v && CFGetTypeID(v) == CFStringGetTypeID()) ? CFBridgingRelease(CFRetain(v)) : @"?";
}

// The four bytes one actuator takes: SDL's amplitude table, dekuNukem's frequency table. Duplicated here
// on purpose so the probe stands alone; swrumble.c is where the real encoder lives.
static void rumble_pair(uint8_t out[4], int step) {   // step 0..100 up SDL's table
    if (step <= 0) { out[0] = 0x00; out[1] = 0x01; out[2] = 0x40; out[3] = 0x40; return; }
    int hs = step, ls = step;
    unsigned hf_amp = (unsigned)(2 * hs);                  // high band: 2 per step, 0x00..0xC8
    unsigned lf_amp = ls >= 100 ? 0x0072u : (unsigned)(0x0040 + ls / 2) | (ls % 2 ? 0x8000u : 0);
    unsigned hf = 0x74;                                    // 150 Hz, where the actuator is loudest
    out[0] = (uint8_t)(hf & 0xff);
    out[1] = (uint8_t)(hf_amp | ((hf >> 8) & 0x01));
    out[2] = (uint8_t)(0x3D | ((lf_amp >> 8) & 0x80));
    out[3] = (uint8_t)(lf_amp & 0xff);
}

// Output report 0x01: id, counter, eight rumble bytes, then an optional subcommand. Over Bluetooth the
// report is 49 bytes; over USB 64. A frame carrying only rumble still goes out at that length here,
// because a short one is what the pad's firmware has been seen to ignore.
static UInt8 g_counter;
static size_t build_frame(UInt8 *out, size_t cap, int left_step, int right_step, BOOL with_vibration_cmd) {
    uint8_t l[4], r[4];
    rumble_pair(l, left_step);
    rumble_pair(r, right_step);
    memset(out, 0, cap);
    out[0] = 0x01;
    out[1] = (UInt8)(g_counter++ & 0x0f);
    memcpy(out + 2, l, 4);
    memcpy(out + 6, r, 4);
    size_t n = 49;
    if (with_vibration_cmd) { out[10] = 0x48; out[11] = 0x01; }   // EnableVibration(true)
    return n < cap ? n : cap;
}

static IOReturn try_lengths(IOHIDDeviceRef dev, const UInt8 *frame, size_t built, size_t *used) {
    static const size_t cand[] = {49, 50, 64, 10, 48};
    IOReturn last = kIOReturnError;
    for (size_t i = 0; i < sizeof cand / sizeof *cand; i++) {
        size_t n = cand[i];
        if (n > built) continue;
        UInt8 buf[128];
        memset(buf, 0, sizeof buf);
        memcpy(buf, frame, n);
        last = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x01, buf, (CFIndex)n);
        printf("      SetReport(len=%zu) -> 0x%08x %s\n", n, last, last == kIOReturnSuccess ? "OK" : "");
        if (last == kIOReturnSuccess) { *used = n; return last; }
    }
    return last;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL do_write = YES;
        for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--dry")) do_write = NO;

        IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
        IOHIDManagerSetDeviceMatching(mgr, NULL);
        IOReturn mo = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
        printf("IOHIDManagerOpen -> 0x%08x\n\n", mo);

        CFSetRef set = IOHIDManagerCopyDevices(mgr);
        if (!set) { printf("no devices\n"); return 1; }
        CFIndex count = CFSetGetCount(set);
        printf("HID devices visible: %ld\n", (long)count);

        IOHIDDeviceRef found[16];
        int nfound = 0;
        IOHIDDeviceRef *all = calloc((size_t)count, sizeof *all);
        CFSetGetValues(set, (const void **)all);
        for (CFIndex i = 0; i < count; i++) {
            IOHIDDeviceRef d = all[i];
            long vid = prop_int(d, CFSTR(kIOHIDVendorIDKey));
            long pid = prop_int(d, CFSTR(kIOHIDProductIDKey));
            if (vid != NINTENDO_VID) continue;
            printf("\n[Nintendo] %s  vid=0x%04lX pid=0x%04lX  transport=%s\n",
                   prop_str(d, CFSTR(kIOHIDProductKey)).UTF8String, vid, pid,
                   transport_of(d).UTF8String);
            printf("           usagePage=0x%lx usage=0x%lx  location=0x%lx\n",
                   prop_int(d, CFSTR(kIOHIDPrimaryUsagePageKey)),
                   prop_int(d, CFSTR(kIOHIDPrimaryUsageKey)),
                   prop_int(d, CFSTR(kIOHIDLocationIDKey)));
            if (nfound < 16) found[nfound++] = (IOHIDDeviceRef)CFRetain(d);
        }
        free(all);
        CFRelease(set);

        if (nfound == 0) { printf("\nno Nintendo pad visible over IOHID\n"); return 2; }

        // Which pad, and what can it take?
        IOHIDDeviceRef pro = NULL;
        for (int i = 0; i < nfound; i++) {
            if (prop_int(found[i], CFSTR(kIOHIDProductIDKey)) == PRO_PID) { pro = found[i]; break; }
        }
        if (!pro) { printf("\nPro Controller (0x2009) not among them\n"); return 3; }

        printf("\n=== Pro Controller: report descriptor ===\n");
        CFTypeRef rd = IOHIDDeviceGetProperty(pro, CFSTR(kIOHIDReportDescriptorKey));
        if (rd && CFGetTypeID(rd) == CFDataGetTypeID()) {
            CFDataRef dd = (CFDataRef)rd;
            printf("descriptor bytes: %ld\n", (long)CFDataGetLength(dd));
            const UInt8 *b = CFDataGetBytePtr(dd);
            // Just look for output items: 0x91 is Output, and the report id in play is logged raw.
            int ids = 0;
            for (CFIndex i = 0; i + 1 < CFDataGetLength(dd); i++) {
                if (b[i] == 0x85) printf("  report id 0x%02X\n", b[i + 1]);
                if (b[i] == 0x91) ids++;
            }
            printf("  output items (0x91): %d\n", ids);
        } else {
            printf("no descriptor property\n");
        }

        printf("\n=== Pro Controller: open ===\n");
        IOReturn o1 = IOHIDDeviceOpen(pro, kIOHIDOptionsTypeNone);
        printf("Open(kIOHIDOptionsTypeNone) -> 0x%08x %s\n", o1,
               o1 == kIOReturnSuccess ? "OK" : (o1 == kIOReturnExclusiveAccess ? "EXCLUSIVE" : ""));
        if (o1 != kIOReturnSuccess) {
            IOReturn o2 = IOHIDDeviceOpen(pro, kIOHIDOptionsTypeSeizeDevice);
            printf("Open(Seize) -> 0x%08x %s\n", o2,
                   o2 == kIOReturnSuccess ? "OK (seized: GameController's input dies)" : "");
            if (o2 != kIOReturnSuccess) {
                printf("\nVERDICT: the pad cannot be opened as an IOHIDDevice while gamecontrollerd holds it.\n");
                return 4;
            }
        }

        if (!do_write) { printf("\n--dry: not writing\n"); return 0; }

        printf("\n=== Write test: neutral frame, then a burst ===\n");
        UInt8 frame[128];
        size_t used = 0;
        size_t n = build_frame(frame, sizeof frame, 0, 0, NO);
        IOReturn w = try_lengths(pro, frame, n, &used);
        printf("  neutral frame -> 0x%08x\n", w);
        if (w != kIOReturnSuccess) { printf("\nVERDICT: opened, but output report 0x01 is refused.\n"); return 5; }

        // EnableVibration: without it the firmware stays mute, as it does for a Joy-Con over Bluetooth.
        printf("\n=== Subcommand 0x48 0x01 (EnableVibration) ===\n");
        n = build_frame(frame, sizeof frame, 0, 0, YES);
        IOReturn e = IOHIDDeviceSetReport(pro, kIOHIDReportTypeOutput, 0x01, frame, (CFIndex)used);
        printf("  enable -> 0x%08x\n", e);
        usleep(300000);

        printf("\n=== Burst: weak, strong, silent (watch and feel the pad) ===\n");
        int steps[] = {25, 60, 100, 100, 0};
        const char *names[] = {"weak 25%", "medium 60%", "strong 100%", "strong 100% again", "silent"};
        for (int i = 0; i < 5; i++) {
            n = build_frame(frame, sizeof frame, steps[i], steps[i], NO);
            IOReturn r = IOHIDDeviceSetReport(pro, kIOHIDReportTypeOutput, 0x01, frame, (CFIndex)used);
            printf("  %-20s step=%3d -> 0x%08x\n", names[i], steps[i], r);
            usleep(700000);
        }
        n = build_frame(frame, sizeof frame, 0, 0, NO);
        IOHIDDeviceSetReport(pro, kIOHIDReportTypeOutput, 0x01, frame, (CFIndex)used);

        printf("\nVERDICT: output report 0x01 reaches the pad from a second holder.\n");
        printf("         length used: %zu bytes;  GameController's input kept working if it did not disconnect.\n", used);
        return 0;
    }
}
