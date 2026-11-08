# Data over Sound — iOS proof of concept

A minimal SwiftUI app that sends a short UTF-8 text message from one iPhone to another using
audible frequency-shift-keyed (FSK) tones. The sender synthesizes the tones and plays them with
`AVAudioEngine`. The receiver captures the microphone and finds the dominant tone in each window
with an FFT from Accelerate (`vDSP`).

This is a separate experiment. It does not touch the Android app in `SoundTest/` and is **not**
wire-compatible with it: there is no Huffman compression, no Reed-Solomon coding, and it uses a
different tone plan.

## Layout

```
ios/
├── DataOverSoundPoC.xcodeproj        Xcode project (one iOS app target, shared scheme)
├── DataOverSoundPoC/                 App: SwiftUI UI, AVAudioSession/AVAudioEngine, mic pipeline
│   ├── DataOverSoundPoCApp.swift
│   ├── ContentView.swift
│   ├── AudioTransceiver.swift
│   └── ListenPipeline.swift
└── Core/                             Swift package with the platform-independent modem
    ├── Package.swift
    ├── Sources/DataOverSoundCore/    configuration, framing/CRC, synthesis, FFT, detection, receiver
    └── Tests/DataOverSoundCoreTests/ deterministic unit tests (no audio hardware)
```

The app target compiles the `Core/Sources` files directly, so it has no package dependency. The
package exists so the modem can be unit-tested with `swift test` on macOS or Linux.

## Requirements

- A Mac with **Xcode 15 or later** (the project uses generated Info.plist keys and Swift 5.8+ APIs).
- **Two physical iPhones on iOS 16 or later.** The Simulator has no usable acoustic path between
  two devices, and its microphone input is often unavailable.
- An Apple ID added to Xcode (Xcode › Settings › Accounts). A free Personal Team is enough to run
  on your own devices. The project does not include a team, certificates, or provisioning profiles.

## Build and install on two iPhones

1. Open `ios/DataOverSoundPoC.xcodeproj` in Xcode.
2. Select the **DataOverSoundPoC** target › *Signing & Capabilities*:
   - Choose your **Team**.
   - Change the **Bundle Identifier** from `com.example.dataoversound.poc` to something unique,
     for example `com.<yourname>.dataoversound.poc`.
3. Connect the first iPhone over USB and select it as the run destination. On iOS 16+, enable
   **Developer Mode** (Settings › Privacy & Security › Developer Mode) when prompted.
4. Press **Run** (⌘R). With a free Personal Team, the first launch may need you to trust the
   developer on the phone: Settings › General › VPN & Device Management.
5. Repeat for the second iPhone.

Command-line build check without signing, which does not produce an installable app:

```sh
cd ios
xcodebuild build -project DataOverSoundPoC.xcodeproj -scheme DataOverSoundPoC \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

## Test procedure (listen, then send)

1. Put both phones in a quiet room, 20–50 cm apart, with the bottom speaker of the sender pointing
   toward the receiver's bottom microphone. Disable silent mode and turn the **sender's volume up**.
2. On the **receiver**, tap **Listen**. The first time, allow microphone access. The status
   should read `Listening at 48000 Hz… waiting for start tone`.
3. On the **sender**, type a short message (the counter shows UTF-8 bytes out of 32) and tap
   **Send**. You will hear a sequence of beeps lasting about 3–17 seconds, depending on length.
4. The receiver's status changes to `Receiving…` when it hears the start tone. When the end tone
   arrives, the message appears under **Received**. A damaged transmission is discarded and the
   status says why (for example `checksum mismatch`). The receiver keeps listening.
5. Tap **Stop listening** when done. Leaving the app (background) also stops audio.

Things to try: emoji and accented text (multi-byte UTF-8), a message longer than 32 bytes (it is
truncated on a character boundary before sending), increasing the distance, and background noise.

Troubleshooting:

- **Nothing happens on the receiver.** Check the sender's volume and silent mode, and move the
  phones closer. Bluetooth headphones or AirPods on either phone change the audio route; disconnect them.
- **"Microphone access denied".** Enable it in Settings › Privacy & Security › Microphone.
- **Frequent "checksum mismatch".** The room is too noisy or reverberant, or the phones are too far apart.

## Wire format (version 1)

Frame bytes, with multi-byte integers big-endian:

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | Version, `0x01` |
| 1 | 1 | Payload length `L`, 1…32 (the maximum is configurable, up to 255) |
| 2 | L | UTF-8 text. The sender cuts it only between whole characters (grapheme clusters). |
| 2+L | 2 | CRC-16/CCITT-FALSE (poly `0x1021`, init `0xFFFF`, no reflection, no final XOR) over bytes `0..<2+L` |

Each frame byte is split into two 4-bit nibbles, high nibble first. On air:

```
[silence 150 ms] START(300 ms) { DATA(nibble) 120 ms, SEP 100 ms } × 2·(L+4) END(300 ms) [silence 150 ms]
```

| Symbol | Frequency |
|---|---|
| DATA n (n = 0…15) | 1500 + 150·n Hz (1500…3750 Hz) |
| SEP (separator) | 4050 Hz |
| START | 4350 Hz |
| END | 4650 Hz |

The amplitude is 0.5 of full scale. Each tone has a 5 ms raised-cosine fade in and out, and phase
is continuous across tones. The separator after every data tone lets the receiver tell repeated
nibbles apart without a shared clock. This follows the idea of the Android app, which uses its
handshake-start tone as a separator.

Throughput is 0.44 s per byte, about 2.3 B/s. A 32-byte payload takes about 16.7 s on air.

### Receiver algorithm

1. Microphone samples (mono, channel 0, at the hardware rate: 48 kHz on current iPhones, and 16 kHz
   and 44.1 kHz are also supported) are copied in the tap callback and handed to a serial queue.
   No DSP runs on the real-time audio thread. If more than 32 chunks are queued, audio is dropped
   and the receiver resets, rather than decoding a stream with a gap in it.
2. Sliding Hann windows of about 40 ms (2048 samples at 44.1 or 48 kHz), with a hop of a quarter window.
3. For each window, take the `vDSP_fft_zrip` power at each of the 19 tone bins, using the maximum
   of the bin and its two neighbours. A window counts as a tone only if all of these hold:
   - The RMS level is at least 0.0005.
   - The winning tone holds at least 25% of the window's energy. This rejects speech, noise, and
     off-band tones.
   - The winning tone is at least 2.5 times stronger than the runner-up. This rejects windows that
     straddle a tone change.
4. A tone is accepted after 3 consecutive windows agree. A frame starts at START. Only the first
   DATA after each SEP is kept, so a glitch cannot duplicate a nibble. The header is validated as
   soon as 2 bytes have arrived, and the whole frame is decoded at END.
5. A frame is rejected and never shown if any of these happen: wrong version or length, wrong
   nibble count, CRC mismatch, invalid UTF-8 (strict decoding, no replacement characters), or no
   accepted tone for 1.5 s.

`FSKConfiguration.validate(sampleRate:)` checks that each tone sits below 0.45·fs, that tones are at
least 4 FFT bins apart, and that every segment holds enough full analysis windows to be detected.
It runs before sending or listening.

### Audio session

The app uses `.playAndRecord` with mode `.measurement`, which turns off voice processing and
automatic gain control that would distort tones, and `.defaultToSpeaker`, which routes output to
the loudspeaker instead of the earpiece. It asks for a 48 kHz sample rate but works with whatever
rate the hardware actually uses.

It is half-duplex: the app is either sending or listening. Audio stops when:

- Another audio session interrupts (a call, Siri, an alarm).
- The audio route or engine configuration changes, for example when headphones are plugged in.
- The system resets media services.
- The app goes to the background.

Late callbacks from a stopped operation are ignored using an operation ID.

## Limitations

- **No encryption or authentication.** Anyone within earshot can record and decode the message, or
  inject a fake one. The CRC detects accidental damage only.
- **No error correction and no compression.** One wrong tone loses the whole message, which is
  then rejected rather than shown corrupted. There are no retries or acknowledgements.
- **Audible and slow** by design. The 1.5–4.7 kHz tones are chosen for reliability on phone
  speakers, not discretion. About 2.3 B/s, and at most 32 bytes per message by default.
- **Sensitive to noise, distance, and reverberation.** Expect it to work at short range in a quiet
  room. Loud speech or music near 1.5–4.7 kHz, hard reflective rooms, cases covering the speaker or
  microphone, and Bluetooth audio routes all reduce reliability. Detection thresholds were tuned on
  synthetic signals only.
- No hardware-performance claims are made: range, error rate, and supported device models have
  not been measured.
- Foreground only. There is no background audio mode.
- Not compatible with the Android app's protocol.

## What has been verified

| Check | Status |
|---|---|
| `swift test` in `ios/Core` on Linux (Swift 6.0.3, portable Goertzel backend): 30 tests covering CRC, framing, UTF-8 truncation and validation, tone classification, synthesis, and synthetic end-to-end decoding with noise, echo, attenuation, random chunking, corruption, timeout, and reset | **Passed** |
| Core builds without warnings under `-strict-concurrency=complete` (Linux) | **Passed** |
| Xcode project file parses (Python `pbxproj`), all referenced sources exist, scheme XML is valid, app Swift files pass `swiftc -parse` (syntax only) | **Passed** |
| `swift test` on macOS (GitHub Actions `macos-15`, Xcode 16.4), using the Accelerate `vDSP` FFT backend: all 30 tests, including a test that cross-checks vDSP power against Goertzel. That test caught and fixed a Hann window scaling bug. | **Passed** in CI |
| `xcodebuild` unsigned build for the iOS Simulator and for `generic/platform=iOS` (same CI job), with no Swift compiler warnings | **Passed** in CI |
| Install on physical iPhones, microphone permission flow, and acoustic phone-to-phone round trip | **Not verified.** Follow the test procedure above. |

## Running the unit tests

```sh
cd ios/Core
swift test
```

On macOS, the tests use the Accelerate FFT. On Linux, they use the portable Goertzel analyzer,
which computes the same DFT bins.
