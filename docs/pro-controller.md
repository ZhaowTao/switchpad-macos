# Why a Pro Controller kept rumbling (and why it stopped taking key releases)

*A hardware failure report, not a feature announcement.*

`swr-haptic` drives a Pro Controller over its own HID output report and it works: a sweep changes texture as the
frequency climbs, and a melody played through the actuator is recognisable when the pad rests on a table. An
experimental attempt to put the same encoder inside a game engine did **not** work. One press left the pad rumbling
indefinitely and the game believing a button was still held. This document is what that failure taught us, with the
measurements and the parts we could not prove separated.

The integration has been withdrawn. It is not in any pull request, and this repository does not contain it.

## Two very different things

| | `swr-haptic` (this repository) | experimental engine integration |
|---|---|---|
| Who writes reports | one short-lived process, one device open | a game process that already owns several HID readers |
| How long a value is held | tens to hundreds of milliseconds, then an explicit neutral frame | driven by game state, indefinitely |
| How often it writes | a frame every 10 ms for a bounded duration | up to ~600 frames/second, unbounded |
| What else is on the device | nothing | input-report callbacks, motion, SPI calibration subcommands, `GameController` |
| Result | verified on hardware | **failed on hardware** |

The same four bytes were correct in both. The difference is everything around them.

## The measurement

Instrumentation in the experimental build logged one line per second. Across 106 lines:

```
silences=0                     the watchdog never fired, not once
live=1     in 3 lines
live=0     in 103 lines        it was writing neutral almost the whole time, and the pad still rumbled
writes    9 -> 637 in 1 s     ~600 frames/second, 49 bytes each
writes 1300 -> 1924 in 1 s
rebinds=0                      device was opened once; this was not a per-frame rebinding bug
```

The pad still rumbling while 103 of 106 samples say "neutral" is the whole bug in one line. A neutral frame was
written; the actuator did not stop.

## Four semantics we dropped

The console, SDL, other successful macOS implementations, and the engine's own Switch 2 rumble path all do four
things that the experimental integration did not.

| | What we did | What a working path does |
|---|---|---|
| **Report type** | `0x01`, 49 bytes, with a zeroed subcommand byte on every frame | `0x10` — *rumble only*. `0x01` is *rumble and subcommand*; it is for frames that also carry a subcommand |
| **Cadence** | one write per game frame, ~600/s | at most one report every ~30 ms, holding the strongest value in each window |
| **Stopping** | one neutral frame, no acknowledgement | several neutral frames in a row, because a write-without-response can be lost |
| **Device ownership** | a second `IOHIDManager` and a second `IOHIDDeviceOpen` on a device the engine already held | one holder; the rumble writer reuses the HID device the input path already has |

dekuNukem's `bluetooth_hid_notes.md` defines `OUTPUT 0x01` as "Rumble and subcommand" and `0x10` as "rumble only".
A successful third-party macOS implementation writes `0x10` with an 8-byte body on a ~30 ms timer and sends a quiet
frame three times before stopping. The engine's own Switch 2 rumble path says it plainly: *"then a few packets of
silence (a write without response can be lost)"*, and its protocol plays each sampled value for 5 ms. We had that
correct implementation in the same tree and did not copy it.

## Why it would not stop

`nn::hid` vibration is **persistent device state**: the actuator keeps the last value it was given until something
changes it. The engine's HLE only calls the output path when a motor value differs from the previous one, so a game
that sends one value and then goes quiet produces no further calls.

`CoreHaptics`, the path being replaced, is built from finite events: a ~0.5 s pulse ends by itself. That is an implicit
time limit the game never had to implement. Bypassing `CoreHaptics` removed the limit too, and we replaced it with
nothing. The firmware simply held the last frame.

We then added a watchdog, and it never fired. Its condition was:

```c
if (d->live && now - d->last > timeout) { write neutral; }
```

but writing neutral sets `d->live = 0` immediately. The watchdog therefore trusted a single unacknowledged write. On a
Bluetooth link that drops packets — we measured ~10 % lost input reports on a Joy-Con, with 26–60 ms gaps — one lost
neutral frame means the software believes it is silent forever while the actuator is not. This part is provable from
the code and the log, not inferred.

Three candidate causes for the lost neutral were **not** distinguished: a dropped packet, a `0x01` frame with an empty
subcommand being rejected, and a counter collision between two holders incrementing independently. Any of them is
sufficient; we do not know which one happened.

## Why a button appeared stuck

This is the part we **cannot** prove, and it is worth being exact about it.

The hypothesis: ~600 compound 49-byte `0x01` frames per second, each carrying a subcommand field, sent by a second
holder on a device that also carries input reports, motion and calibration subcommands, crowded out or corrupted the
input stream. If the button-release report never arrived, `GCController` would keep reporting the last value and the
game would keep playing the note. The old build, using `CoreHaptics` and no second HID holder, was normal on the same
hardware and in the same scene, which is what makes our change the cause rather than a coincidence.

What we did **not** have: a packet capture, or a trace showing a specific missing release report. The cadence figure
is solid — SDL's own driver has `#define RUMBLE_WRITE_FREQUENCY_MS 30` and gates writes on it, with a separate
`RUMBLE_REFRESH_FREQUENCY_MS 50` for refreshing a held value. The stronger claim that writing faster can switch the
controller off comes from a third-party comment about SDL and was not verified line by line. So: strong inference,
consistent with every symptom, not a demonstrated mechanism.

## Why ordinary Pro Controllers are fine

Three layers, in order of how much they matter:

1. **Most players never leave `GameController`.** `gamecontrollerd` owns cadence, pulse duration and silence. Its
   haptics degrade — no advanced player on macOS 26+, one merged engine for both grips, 0.5 s pulses — but the result
   is *soft*, not *wrong*. Nothing sticks.
2. **Implementations that do bypass it** carry the four semantics above. They are not optional extras; they are the
   protocol's timing and reliability contract.
3. **The engine already had a correct path** for a newer controller, merged before this experiment. The failure was
   not a missing reference implementation, it was not reading it.

## The generalisation, and the part that should worry you

The same mistake happened once before in this project: replacing a verified behaviour with one that *looked more
correct* (a real six-axis history ring in place of repeated newest samples) made every gesture miss, and was reverted.
Both times the replacement carried only the visible action — "write a report", "return 16 states" — and dropped the
invisible contract that the old path had been providing for free.

The Joy-Con path in [nxnative PR #2183](https://github.com/seedds/nxnative/pull/2183) is event-driven and also sends a
single neutral frame on silence. It was verified in play and it works, but the same latent risk exists there: its
subcommand frames carry the current rumble bytes and so refresh the state naturally, and the game used for testing
changes values continuously. A long quiet value on a lossy link is the untested case. It is listed as a known
limitation rather than hidden.

## What a correct integration would look like

Not a tuned parameter — a different shape:

- `0x10` for rumble-only frames; reserve `0x01` for frames that actually carry a subcommand such as `0x48 0x01`.
- One writer, reusing the HID device the input path already owns. One counter.
- A dedicated queue with a ~30 ms tick, taking the strongest value in each window rather than every frame.
- Silence as a *state*, not an event: keep sending neutral frames until the actuator is known stopped, at least three
  times, and never let a pending stop depend on one unacknowledged write.
- `0x48 0x01` (`EnableVibration`) after opening over Bluetooth. It is real: without it the firmware stays mute.

Those are the terms on which this repository may eventually grow a Pro Controller backend. Until then the CLI is the
only supported Pro Controller path, and it is deliberately short-lived.

## Reproduce the part that does work

```sh
make
./build/swr-haptic list
./build/swr-haptic sweep       # 90 to 1252 Hz, texture changes with the pitch
./build/swr-haptic tune        # a melody; rest the pad on a table to hear it
```

Put the pad on a table. The table is the sounding board, and a frequency sweep that changes audible pitch is the
cheapest independent check that the frequency codes, not just the amplitudes, are reaching the actuator.

## Sources

- [dekuNukem, Nintendo_Switch_Reverse_Engineering](https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering) —
  `bluetooth_hid_notes.md` (output report IDs), `rumble_data_table.md` (frequency rows), subcommand `0x48`.
- [SDL, `SDL_hidapi_switch.c`](https://github.com/libsdl-org/SDL) — the 101-step amplitude table, packing, subcommand
  round-trip timing.
- [nxnative#2148](https://github.com/seedds/nxnative/issues/2148) — measured game vibration amplitudes, and why a
  linear gain is the wrong tool for them.
- [MacNativeGames](https://github.com/ly05010419/MacNativeGames) — an independent macOS implementation whose report
  choice and cadence corroborate the four semantics above.
