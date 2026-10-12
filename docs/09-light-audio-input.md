# 09. Light and sound as an input channel

- **Status**: proposal, not implemented
- **Last updated**: 2026-10-12
- **Why this document exists**: the chosen transfer route ([08-rp2350-pizero.md](08-rp2350-pizero.md), section 7b)
  uses a microSD card for input and a QR code on the device screen for output. That works, but it makes
  the phone/PC do a file copy each time. A **light or sound receiver** on the device could take the
  place of the missing camera far more cheaply than image-based QR decoding.

---

## 1. Why light/audio instead of a camera

| | Camera + QR decode | **Light receiver** | **Sound receiver** |
|---|---|---|---|
| Extra part | Pi camera (CSI) or SPI camera module | photodiode/phototransistor module (~¥100–500) | electret/PDM microphone module (~¥300–800) |
| Firmware work | image capture, binarisation, finder detection, perspective, Reed-Solomon | threshold a digital/analog signal, frame it, check CRC | FSK/OOK demodulation, frame it, check CRC |
| Data rate | QR frames: a few hundred bytes per frame | ~5–15 B/s (screen flicker, OOK) | **~0.2–2 kB/s** (audio FSK) |
| Sender side | any QR-capable app | a web page that flashes the screen | a web page that plays tones (Web Audio) |
| Physical property | needs line of sight | **needs line of sight** (hard to attack remotely) | in-band: anyone in earshot can transmit |

The decisive point: **we do not need to decode a QR image at all.** Light and sound only need a
modulated stream, so the firmware side is a small, well-understood DSP/framing problem instead of a
computer-vision problem. That is why this is attractive even though a camera would be the "obvious" answer.

## 2. Hardware constraints on the RP2350-PiZero

### 2.1 The 3-pin debug interface is not a good input

The board brings out a **3-pin debug interface** (SWCLK / GND / SWDIO) as solder pads.

- Those pins are for **SWD debugging**; they are not general-purpose ADC inputs, and the ADC on the
  RP2350 is only available on GPIO26–GPIO29. **An analog sensor cannot be read there.**
- The pads are not a connector: using them means soldering or a pogo-pin jig.
- Conclusion: fine for a debug probe, **not** the place to attach a sensor.

### 2.2 The 40-pin header with the standard LCD HAT

The Waveshare 1.3inch LCD HAT uses 14 of the 28 available GPIOs:

| Use | GPIO |
|---|---|
| LCD (SPI0) | SCLK 11, MOSI 10, CS 8, DC 25, RST 27, BL 24 |
| Joystick | UP 6, DOWN 19, LEFT 5, RIGHT 26 (ADC0), PRESS 13 |
| Buttons | KEY1 21, KEY2 20, KEY3 16 |

**Both ADC-capable header pins (GPIO26, GPIO27) are already taken by the HAT**, so there is **no free
ADC pin** on the header. Free GPIOs are 0, 1, 2, 3, 4, 7, 9, 12, 14, 15, 17, 18, 22, 23 — but the HAT
is mounted flush on the header, so nothing can be plugged underneath it.

### 2.3 Therefore: digital sensors, and a way to reach the free pins

1. **Use a sensor with a digital output.** Then no ADC is needed and any free GPIO works:
   - light: a photodiode/phototransistor module with a comparator (LM393-type boards are commodity
     parts) → clean HIGH/LOW by light threshold;
   - sound: a **PDM or I2S digital microphone** module → a bit stream the RP2350 can sample in software
     (or with PIO), no ADC required.
2. **Reach the free pins without soldering**:
   - a **40-pin stacking header** (female–female) between the board and the HAT exposes the same pins
     again on top; a jumper wire from a spare socket to the sensor breakout needs no soldering;
   - or, for v0.2, a **custom carrier board** that assigns pins freely (this also removes the HAT's
     pin collision entirely and is the clean long-term answer).
3. **Do not forget the constraint this creates**: the sensor is then on the header, so the enclosure
   needs a window for it (the enclosure design in [hardware/enclosure](../hardware/enclosure/README.md)
   already has unmeasured cut-outs; a sensor window would be added there).

## 3. Protocol sketch

Whatever the physical channel, the payload is the same as today: a PSBT, or a UR part. A minimal
framing that is easy to verify:

```
preamble (0xAA 0xAA) | version (1B) | length (2B, little endian) | payload | CRC-32 (4B)
```

- **Light, OOK**: the sender flashes the screen (white = 1, black = 0) using a self-clocking encoding
  (e.g. Manchester) so that the receiver does not depend on an exact clock. At 30–60 symbols/s this
  gives roughly 5–15 B/s; a 200-byte PSBT takes a few tens of seconds. Acceptable for a signature
  request, and it needs only a threshold on the light sensor.
- **Sound, FSK**: two tones (e.g. 1.5 kHz and 3 kHz) at ~1 kB/s, or ultrasonic carriers if the user
  prefers the exchange to be inaudible. Faster, but in-band.
- The device **reports progress and the CRC result on its screen**; a failed CRC is shown as an error
  and nothing is signed.
- The sender side can be a **static web page** (Web Audio for sound, a canvas for light). No app
  installation, which matters for adoption.

## 4. Security notes

| Concern | Note |
|---|---|
| In-band channel (sound) | Anyone within earshot can transmit. The device must therefore always **display and require confirmation** of what it is about to sign — the same rule as everywhere else in this project. |
| Line-of-sight channel (light) | Harder to attack remotely; a good default. |
| Denial of service | A jammed channel is an inconvenience, not a loss of funds. |
| Data integrity | CRC-32 catches corruption; the signed result is verified by the host afterwards (Bitcoin Core, or the wallet's own re-check). |
| Not a QR replacement for output | The device still shows its result as a QR code and/or writes it to the SD card. |

## 5. What can be implemented and verified without hardware

The receiving logic is pure software and can be developed and tested on a PC today:

1. **Bit-level framing** (preamble, length, CRC) with unit tests, including corrupt frames.
2. **OOK decoder for light**: input is a sampled light-level array; output is bits. Test signals can be
   generated synthetically (and by a phone screen recording, later).
3. **FSK demodulator for sound**: input is a sampled audio array; output is bits. Synthetic signals
   with noise and frequency offset make this testable without a microphone.
4. **A synthetic channel model** for tests: modulate a known payload, add noise/gain drift, demodulate,
   and require the original bytes back.
5. A `zhww` CLI command that takes a recorded signal (a file of samples) and prints the decoded frame —
   the same code path the device will use.

None of this needs the board. The hardware only decides *which* sensor and *which* pin.


## 6. The light receiver: what to actually buy

**Decision: the light path is the input channel** (see §9 for why it beat the camera on cost). The
module to buy is the commodity **"LM393 light sensor" board**: a photodiode or phototransistor, a
comparator, a trimmer, and — on the usual 4-pin version — **both an analog (`AO`) and a digital (`DO`)
output**. Roughly **¥300–600**, sold by Akuzuki Denshi, aitendo, Amazon.co.jp and Yahoo Shopping, in
multi-packs (for example a 3-pack of "photosensitive diode, digital/analog output" boards).

| Candidate | Output | Speed | Verdict |
|---|---|---|---|
| **LM393 board with a photodiode or phototransistor, `AO` + `DO`** | analog **and** digital | kHz-class | **Buy this.** The analog output goes to the ADC so the firmware can threshold in software (robust against a changing ambient level); the digital output is a free fallback if no ADC pin is available |
| LM393 board with a **photoresistor (LDR/CdS)** | analog + digital | ~10–100 ms | Avoid: too slow for a screen flickering at 30–120 Hz, and CdS cells are being phased out |
| TSOP4838 infrared receiver | digital, demodulated | fast | Excellent against ambient light, but a phone screen emits no IR, so the sender would need an IR emitter |
| VEML7700 / BH1750 (I²C lux sensor) | I²C | ~100 ms per reading | No threshold to set, but a few bytes per second at best |

### How it connects

| Module pin | Goes to | Why |
|---|---|---|
| `AO` (analog) | **an ADC pin (GPIO26/27)** | The firmware samples it and applies an adaptive threshold with hysteresis, so a slowly changing room light does not flip the decision |
| `DO` (digital) | a free GPIO (optional) | A hardware-threshold path; useful as a cross-check or if no ADC is free |
| `VCC` | 3.3 V | These boards accept 3.3–5 V |
| `GND` | GND | — |

Both ADC-capable pins were blocked by the old Waveshare HAT; with the chosen Adafruit Mini PiTFT
(#4393) the header is mostly free again, so **at least one ADC channel is expected to be available**.
That has to be confirmed against Adafruit's pin list when ordering: if the display's two buttons happen
to occupy GPIO26 and GPIO27, the receiver falls back to the digital output and keeps working.

Sampling and decoding plan (all host-testable): sample the ADC at a few kHz, remove the slow ambient
level with a moving average, threshold with hysteresis, decode **Manchester** symbols, then the frame
(preamble, length, CRC-32) from §3, and finally hand the resulting **UR string** to the multipart UR
receiver in `src/transport/ur_receive.zig` — the same assembler the camera path would have used.

Nothing here has been bought or measured yet; prices are approximate and pin assignments are to be
confirmed on the real board.

## 7. How to physically connect anything at all

**This section is mostly resolved by the display decision**: the chosen Adafruit Mini PiTFT (#4393)
is only 38.6 x 24.5 mm, leaves the rest of the 40-pin header reachable, and adds a Qwiic/STEMMA QT
port that sensors can plug into directly. The options below remain relevant if the Waveshare HAT is
ever used again.

The problem (with the old Waveshare LCD HAT): it plugs onto the 40-pin header and covers the whole
board (65 x 30 mm). **Every free GPIO is on that header, and the HAT hides all of them.** Nothing can be
plugged underneath, so a sensor or camera has nowhere to go as the build stands today.

Options, in order of how little they change the project:

| Option | How it works | Soldering | Trade-off |
|---|---|---|---|
| **A. 40-pin T-splitter board (recommended first step)** | A small board that has a female socket on the bottom (for the board's male header) and **two** 40-pin sockets on top. The LCD HAT goes on one, the sensor or camera wiring on the other, with jumper wires. | none | Adds ~10 mm of height, so the enclosure needs adjusting; the splitter must be female-bottom (most Pi "T-type" splitters are) |
| **B. Replace the HAT with a jumper-wired display** | Use a display module connected with a 6-8 wire jumper cable instead of a HAT, leaving the rest of the header reachable. | none | Loses the proven HAT; the enclosure must be redesigned around the module |
| **C. Carrier shield (the clean v0.2 answer)** | A small PCB that plugs into the 40-pin header and carries the sensor, the camera connector, the microSD and a display connector in one piece. | none (factory-assembled) | Leaves "assemble from commodity parts only"; the design would be published like the rest |
| D. Solder to the debug pads / header pins | - | required | Rejected: it breaks the no-soldering rule and the debug pads have no ADC anyway |

### Which pins are actually free

The HAT occupies 14 of the 28 available GPIOs:

| Use | GPIO |
|---|---|
| LCD (SPI0) | SCLK 11, MOSI 10, CS 8, DC 25, RST 27, BL 24 |
| Joystick | UP 6, DOWN 19, LEFT 5, RIGHT 26, PRESS 13 |
| Buttons | KEY1 21, KEY2 20, KEY3 16 |
| **Free** | **0, 1, 2, 3, 4, 7, 9, 12, 14, 15, 17, 18, 22, 23** (14 pins) |

Both ADC-capable pins (26, 27) are taken, which is why a **digital-output** sensor is required
(section 2.2). For a camera, SPI1 would be the natural choice; its exact pin mapping has to be
confirmed against the RP2350 function table and the free list above at the point the hardware
arrives.

### What this means for the enclosure

Any of options A-C raises the stack: the splitter adds roughly the height of one header (~10 mm),
and a camera or sensor needs a window in the case. The parametric enclosure in
[hardware/enclosure](../hardware/enclosure/README.md) already has `MEASURED` placeholders for the
board-side cut-outs and would gain a parameter for the extra height and the sensor window.

## 8. Open questions

- Which sensor first: light (simpler, line-of-sight) or sound (faster, usable without aiming)?
- Audio: audible tones (simple, but anyone can hear/transmit) or ultrasonic (quieter, still in-band)?
- Do we accept the stacking-header arrangement, or move straight to a custom carrier board for v0.2?
- Should the device also *transmit* over these channels (an LED or a buzzer), or is the screen enough?

## 9. Decision: a light receiver is the input channel (camera deferred)

Two candidates were weighed: a camera reading a QR code, and a light receiver reading a screen that
flickers.

| | Camera + QR | **Light receiver** |
|---|---|---|
| Cost | ~$25 (about ¥3,800) | **¥300–600** |
| Sender (phone/PC) | Already exists (any wallet that shows a UR QR) | A **static web page** would be written here (no app to install) |
| Payload | UR over QR (published standard, both ends implemented and verified) | The **same UR strings**; only the link layer below them is new |
| Link layer | QR + BC-UR, already done | Written here: Manchester, framing, CRC-32, adaptive thresholding |
| Speed | One frame, effectively instant | ~5–15 B/s, so a ~200-byte PSBT takes roughly 15–40 s |
| Pins | ~5 (SPI1) | **1** (an ADC pin, plus an optional digital one) |
| Hardware risk | Module sourcing, header soldering, SPI/PIO capture | A commodity board that any shop sells |

**Decision: the light receiver.** The camera wins on protocol fit and speed, but it costs roughly ten
times as much, and the protocol concern turns out to be smaller than it looked: the payload stays
**UR**, and the multipart assembler (`src/transport/ur_receive.zig`) takes decoded strings, so it is
**shared by both channels** — the light path only has to deliver the same strings. Writing a
Manchester/framing layer and a one-page sender is work this project can do and test without hardware,
whereas the camera's cost is money the user has to spend.

**Honest costs of this choice**

- **Speed**: a PSBT takes tens of seconds to receive instead of a fraction of a second. Signing is a
  once-in-a-while action, so this is accepted, but it is real.
- **No standard link layer**: the framing and modulation are ours. They are simple enough to test
  hard (synthetic signals with noise, ambient flicker and gain drift), and a failed CRC means nothing
  is signed — but it is not a standard anyone else has reviewed.
- **Ambient light**: indoor lighting flickers at 100/120 Hz, the same order as the data rate. A light
  guide, Manchester encoding and an adaptive threshold are the mitigations (§6).

The camera research stays in [03-hardware-bom.md](03-hardware-bom.md) §2.5 so it can be picked up later.

### What happens next

1. **Sender** (host, no hardware): a static web page that flashes the screen to send a UR string.
2. **Receiver** (firmware, no hardware): ADC sampling, ambient removal, adaptive threshold, Manchester
   decoding, framing and CRC — with synthetic-signal tests.
3. **Join-up**: the decoded string goes into `ur_receive.zig` (already written and tested), giving a
   PSBT from a flickering screen.
