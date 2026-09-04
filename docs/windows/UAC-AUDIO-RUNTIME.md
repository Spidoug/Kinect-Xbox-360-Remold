# Windows UAC audio runtime — V1

The Windows V1 audio path uses Microsoft UACFirmware **01.02.709.00** from Kinect for Windows Runtime v1.8 for the Kinect NUI Audio boot function. The same firmware image is used for models 1414 and 1473.

```text
USB\VID_045E&PID_02AD
  ↓ Microsoft WinUSB
Kinect360RemoldAudioBridge
  ↓ UACFirmware upload
USB re-enumeration
  ↓
USB\VID_045E&PID_02BB&MI_02  OR  USB\VID_045E&PID_02C3&MI_02
  ↓ Microsoft inbox USB Audio
WASAPI capture
  ↓
Remold four-channel application fan-out
```

The build obtains the pinned UACFirmware image, validates it and embeds it into `Kinect360RemoldAudioBridge.exe`. The bridge uploads the raw image through boot bulk endpoints `0x01/0x81`, starts it at the Kinect UAC entry point, then waits for the USB Audio runtime identity.

At runtime the Microsoft USB Audio class driver owns isochronous scheduling. AudioBridge finds the Kinect capture endpoint through MMDevice/WASAPI and publishes the stable Remold 4-channel/16 kHz/S32LE ABI.

Install/Reinstall installs AudioBridge as a persistent delayed-auto product service from `%ProgramFiles%`, independently of whether the RAM-resident firmware currently exposes `02AD` or has already re-enumerated to the `02BB/02C3` UAC family. Setup treats `02BB&MI_02` or `02C3&MI_02` presence plus a running AudioBridge service as transport readiness. Capture quality is a runtime concern: `audio-bridge-status.txt` reports the actual mode, channel count, sample rate and published-frame counters, and Studio surfaces subscription/capture errors to the user.

Capture policy is deliberately phase-preserving for DOA/TDOA:

1. if the Windows shared endpoint already exposes four or more real channels, AudioBridge opens that exact format with event-driven WASAPI;
2. event-driven shared mode uses engine-selected buffer duration/periodicity (`0/0`), as required by WASAPI;
3. if the shared mix is mono/stereo, AudioBridge does **not** ask the Windows mixer to fabricate a four-channel stream;
4. instead it probes the endpoint's native exclusive 4-channel/16 kHz PCM formats and captures them timer-driven;
5. all four channels use one resampling phase when a real shared four-channel endpoint runs above 16 kHz, preserving inter-channel timing.

`audio-bridge-status.txt` exposes `capture_mode`, channel count, sample rate, WASAPI packet counters and `published_frames`. These counters are the authoritative runtime evidence for microphone capture after installation.

The V1 audio path does not require a Remold-authored kernel audio `.sys`.
