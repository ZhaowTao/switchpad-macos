# switchpad-macos

**HD rumble for Nintendo Switch controllers, on a Mac, over the pad's own report.**

A Joy-Con and a Pro Controller both pair with macOS and both play games. Neither rumbles the way it does on a Switch, and a Pro Controller is quieter and flatter still. Everything below was measured on macOS 26.6.2 over Bluetooth, on a 1st-generation Pro Controller and a pair of 1st-generation Joy-Con; other macOS versions were not tested. This repository is the measurement of why, a dependency-free encoder that fixes it, and a command-line tool you can feel the difference with in ten seconds.

```
$ ./build/swr-haptic sweep
sweeping the high band; the texture should sharpen as it climbs
  90 Hz  120 Hz  160 Hz  200 Hz  260 Hz  320 Hz  420 Hz  520 Hz  640 Hz  800 Hz  1000 Hz  1252 Hz
```

Rest the pad on a table while that runs. The table is the sounding board, and the pitch climbs.

## The problem, in three steps

`GameController` gives a Switch pad a haptics route that degrades on its way to the metal. Each step is logged, and each one costs something:

| step | what happens | what it costs |
|---|---|---|
| 1 | `gamecontrollerd` reports **no advanced player** for the pad; `createAdvancedPlayerWithPattern` fails with 4097 | no continuous parameter track: no real frequency modulation |
| 2 | one **plain player**, whose left and right handle engines overwrite each other | no stereo: both grips get the same merged value |
| 3 | events are **0.5 s pulses** with a 0.15 s lead | pitch can only change on a pulse boundary, so texture is coarse |

The amplitudes make it worse. A game tuned for the console's own actuator sends very little: *Ocarina of Time* peaks at **0.06**, and a linear 3× gain leaves it at 0.18 — a whisper. Upstream [nxnative#2148](https://github.com/seedds/nxnative/issues/2148) measured exactly this and proposed a local patch; it is still an open issue, with no merged fix.

## What this does instead

The pad takes an output report. Report `0x01` on a Pro Controller, `0x30` on a Joy-Con, and both carry **eight rumble bytes: four per grip**, each holding a frequency code and an amplitude code for two bands. That is the whole of its haptics interface, and it has none of the three steps above.

The observation this repository rests on: **`GameController` holds a pad's input path but does not own the device.** An `IOHIDDeviceOpen` with `kIOHIDOptionsTypeNone` succeeds while `gamecontrollerd` is reading it, so a second holder can write output reports without seizing input, without a driver, and without touching the pad's connection.

Measured on a Pro Controller over Bluetooth:

```
IOHIDDeviceOpen(kIOHIDOptionsTypeNone)  -> 0x00000000  OK
IOHIDDeviceSetReport(0x01, 49 bytes)    -> 0x00000000  OK
subcommand 0x48 0x01 (EnableVibration)  -> 0x00000000  OK
```

Without `0x48 0x01` the firmware stays mute. With it, the pad plays.

## Quick start

```sh
make
./build/swr-haptic list
./build/swr-haptic play --amp 0.9 --freq 320 --ms 400
./build/swr-haptic sweep
./build/swr-haptic tune
```

```
$ ./build/swr-haptic tune
Pro Controller: Ode to Joy, the first two phrases
  E4    329.6 Hz  250 ms
  F4    349.2 Hz  250 ms
  G4    392.0 Hz  250 ms
  ...
```

That is not a mock-up: the actuator has one degree of freedom and the frequency code is its pitch, so a melody is a list of frequencies. Any melody:

```sh
./build/swr-haptic tune "C5:200 E5:200 G5:400 C6:600"
```

## Using the encoder

`swrumble.c` has no dependencies and no platform code — it turns a vibration value into four bytes, and nothing else.

```c
#include "swrumble.h"

swr_value v = { .amplitude_low = 0.25f, .amplitude_high = 0.9f,
                .frequency_low = 150.0f, .frequency_high = 320.0f };
uint8_t actuator[4];
swr_encode(actuator, &v, 1.0f, 1.0f, 1.0f);   /* gain, curve, frequency blend */
```

Then put those four bytes where the report wants them:

```c
uint8_t report[49];
size_t n = swr_report_pro(report, sizeof report, counter++, left, right, 0, NULL, 0);
IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x01, report, (CFIndex)n);
```

`counter` must advance on every report or the pad drops it as a duplicate.

## The strength curve

`swr_shape(amplitude, gain, gamma)` is `amp^gamma * gain`, clamped. A gamma below 1 lifts the quiet end without touching the loud end, which is what a game with a 0.06 peak needs and what a flat gain cannot do without clipping everything above 0.33:

| input | `gain 3, gamma 1` | `gain 3, gamma 0.5` |
|---|---|---|
| 0.06 | 0.18 (a whisper) | **0.73** |
| 0.33 | 1.00 (clipped) | 0.83 |
| 1.00 | 1.00 | 1.00 |

This is the useful half of [nxnative#2148](https://github.com/seedds/nxnative/issues/2148)'s patch. The other half, a 250 ms hold, compensates a rotor motor's spin-up; these are linear resonant actuators that stop in about ten milliseconds, so holding a pulse smears it instead of strengthening it.

## The protocol, in one page

| | |
|---|---|
| frequency code | `code = round(32 * log2(f / 40))`, so 160 Hz is `0x40` and 320 Hz is `0x60` |
| low band | codes `0x01`–`0x7F`, 41–626 Hz |
| high band | codes `0x21`–`0x9F`, 81.75–1252 Hz; its report field is `(code - 0x20) * 4`, from `0x04` to `0x1FC` |
| amplitude | 101 steps; the high band's code is `2 * step`, the low band's is `0x40 + step / 2` |
| neutral | `00 01 40 40` — not `00 00`, which the firmware reads as the start of a subcommand |
| Pro Controller | report `0x01`, 49 bytes over Bluetooth |
| Joy-Con | report `0x30`, same eight rumble bytes |

The amplitude table is [SDL](https://github.com/libsdl-org/SDL)'s (`SDL_hidapi_switch.c`); the frequency rows are [dekuNukem's](https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering) reverse-engineering notes. Neither is required to build this.

## Status

| | |
|---|---|
| Pro Controller rumble over `0x01` | verified on hardware (Bluetooth, macOS 26) |
| Joy-Con rumble over `0x30` | verified on hardware, in [nxnative PR #2183](https://github.com/seedds/nxnative/pull/2183) |
| Frequency mapping | verified by feel: a sweep changes texture, a melody is recognisable |
| Joy-Con IMU | not part of this repository |
| Input, pairing, player lights | `GameController`'s job, not this one |

## Where this sits

Two layers sit above this library, and only one of them takes patches:

| layer | what it is | gets fixed by |
|---|---|---|
| [seedds/nxnative](https://github.com/seedds/nxnative) | **the engine.** Rebuilds the game's graphics on Metal and talks to the pads | a pull request — [PR #2183](https://github.com/seedds/nxnative/pull/2183) is the Joy-Con half of this work |
| NX2Apple | **a community front end** listed in nxnative's "Community front ends" section (`org.nxnative.NSPortBuilder`): a GUI that packs a game into a double-clickable `.app` and ships its own pinned engine in `Application Support/NX2Apple/engine/<commit>-<digest>/` | upgrading its engine, which only happens after a patch lands upstream |
| this repository | the encoder and the tooling, usable by either, dependent on neither | — |

That ordering is why the PR matters more than the local branch: a fork of the engine reaches one Mac, a merged patch reaches every copy of it, including the one NX2Apple downloads.

## Related

- [seedds/nxnative](https://github.com/seedds/nxnative) — the engine this was written inside, and the PR that upstreamed the Joy-Con half
- [dekuNukem/Nintendo_Switch_Reverse_Engineering](https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering) — the reports, the tables, the subcommands
- [libsdl-org/SDL](https://github.com/libsdl-org/SDL) — the amplitude table and the packing this encoder follows

## License

MIT. The tables are facts measured from the hardware; the code is new.
