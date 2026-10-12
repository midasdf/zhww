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

## 6. Open questions

- Which sensor first: light (simpler, line-of-sight) or sound (faster, usable without aiming)?
- Audio: audible tones (simple, but anyone can hear/transmit) or ultrasonic (quieter, still in-band)?
- Do we accept the stacking-header arrangement, or move straight to a custom carrier board for v0.2?
- Should the device also *transmit* over these channels (an LED or a buzzer), or is the screen enough?
