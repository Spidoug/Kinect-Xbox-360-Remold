# Kinect Xbox 360 Remold V1.0

## V1 contract

V1.0 is the single product baseline in this source tree. ScannerPort has one RAW contract on Windows and Linux: RGB is GRBG8 Bayer, IR is packed 10-bit and Depth is packed 11-bit shift data. Every client and native component uses this same contract.

### SynKinect Studio

- Java 17 target.
- Neutral Home/presentation startup: no module transport is opened until explicit user selection.
- Five instance-owned modules: 3D Scanner, Acoustic Scanner, Microphones, Surveillance and Interactivity.
- Every protocol/service/state/module object is explicitly instantiated before use; module phase begins at `NEW` and hardware remains unopened until activation.
- One central stable Kinect device registry.
- Scanner and Interactivity follow the selected Kinect.
- Surveillance monitors every discovered Kinect concurrently and uses RGB/IR day-night arbitration while foreground.
- Seven synchronized UI locales with one shell-owned language policy.

### 3D Scanner

- per-device depth calibration and noise confidence;
- responsive 192³ live preview;
- full-resolution HQ keyframes;
- robust local-map ICP and loop closure;
- 2× multi-frame subpixel depth super-resolution;
- 288³ final TSDF with 2.3 mm voxel and 9 mm truncation band;
- stable RGB 640×480 color keyframes for the live Scanner;
- quality/photometric multi-view texture fusion;
- indexed OBJ/STL/PLY export, up to 600,000 triangles and 4K texture by default.

### Acoustic Scanner

- raw four-channel 16 kHz block processing independent of UI frame rate;
- GCC-PHAT/TDOA DOA across all six microphone pairs;
- approximate near-field horizontal x/z localization;
- voice-band/SNR/probability VAD with attack/release hysteresis before AUTO steering;
- robust angular clustering, dwell, deadband and slew-rate limits so AUTO follows persistent speech rather than isolated noise;
- adaptive spectral noise suppression after fractional-delay delay-and-sum beamforming;
- MANUAL radar steering remains direct user control;
- Microphones instantiates the same spatial DSP independently from Acoustic Scanner.

### Interactivity

- one in-house SynKinect Body V1 backend using metric Depth segmentation and articulated body geometry;
- calibrated RGB→Depth matching converts accepted keypoints to metric camera-space XYZ;
- derived torso/pelvis/hand/foot joints are built only from valid model-joint relationships;
- per-instance confidence/velocity-aware 3D pose filtering with bounded joint speed;
- all joint coordinates are clamped to the RGB viewport and the full virtual-rig overlay is renderer-clipped to the image card;
- no external pose runtime/model is staged; the body tracker is compiled into the Studio.

### Surveillance

- all connected Kinects monitored concurrently;
- one 10-minute compressed JPEG retention ring in RAM per Kinect;
- motion evaluated from temporal appearance/luminance change in the active video stream;
- 60-second pre-roll written when an event starts;
- synchronized compact MJPEG/AVI event directory with one file per camera;
- RGB in normal light or IR in low light; Surveillance never subscribes Depth;
- IR is released when Surveillance is not the foreground module to preserve RGB consumers.

### Native runtime

- multi-Kinect stable device identity and per-device transport;
- per-device video arbitration: Scanner 3D owns RGB+Depth; Surveillance owns exactly RGB or IR;
- deterministic physical-resource policy: RGB is the idle video mode; IR/Depth run only for real subscribers; projector state follows active Depth/IR demand while healthy endpoint registrations remain device-owned across module reopen;
- model 1473 camera startup uses a post-firmware audio/control keep-alive with a bounded sibling re-enumeration window; fixed-size RGB/IR/Depth assembly tolerates up to five lost USB packets and zero-fills short payloads instead of freezing until a complete frame;
- Windows RGB/IR/Depth uses 8 transfers × 32 packets: the first WinUSB request establishes the ASAP start frame and the remaining requests extend one non-overlapping continuous schedule. Non-disconnect completion errors are resubmitted instead of draining the queue; camera diagnostics are persisted in `%ProgramData%\Kinect360Remold\camera-bridge.log`;
- camera clients retain at most three RGBD pairs (six individual frames), preventing a short CPU or scheduler delay from becoming a long visible catch-up stutter;
- Studio translation catalogs use Java-portable Unicode escapes and logical composite fonts across every module, avoiding Windows code-page corruption and preserving Latin, accented and Japanese glyph fallback; the default UI font scale is `1.22`;
- the pinned Windows UACFirmware 01.02.709.00 image is hash-validated and already constructs its Audio ISO IN descriptor with the supported high-speed `bInterval=4`; no executable firmware byte is modified, camera descriptors remain unchanged, and WinUSB camera transfer geometry uses the effective polling interval;
- normal module close/reopen never resets healthy camera pipes; an endpoint `0x81` transport failure ends only the affected Kinect's current WinUSB camera session, and that device's `CameraNode` reopens a clean handle while other connected Kinects remain running;
- Surveillance IR→RGB checking is evidence-driven with cooldown, not a blind periodic mode toggle;
- Studio 1280×800 is the 100% UI baseline with a uniform readable font multiplier;
- Scanner negotiates stable RGB 640×480 + Depth after module selection; pressing SCAN never restarts or changes the camera transport;
- Kinect v1 HQ uses one firmware priming sequence and a no-frame watchdog that falls back in-place to RGB VGA+Depth;
- derived same-exposure 640×480 RGB remains available from a healthy HQ session;
- module transitions fully release Scanner HQ before VGA Interactivity is activated;
- Linux udev → systemd activation policy with reconnect loops;
- Windows user-mode WinUSB/WASAPI/Media Foundation architecture;
- one multi-client raw four-channel audio bus with independent GCC-PHAT/TDOA + beamforming DSP instances in Microphones and Acoustic Scanner;
- WASAPI raw four-channel policy: native shared 4ch when real, exclusive 4ch/16 kHz fallback when the shared mixer is mono/stereo;
- software ROOT product container validated as a ROOT device/service host, never as a physical WinUSB function;
- Windows virtual camera is a fixed 640×480/30 consumer and never controls the physical sensor mode.

## Source-only native release

No native driver executable/package is committed in the V1 source archive. Windows and Linux native outputs must be generated from the source included in the same release. See `BUILD-DRIVERS.md`.

## Scanner quality

See `SCANNER-QUALITY.md` for the current pipeline, reproducible synthetic benchmarks and comparison with current scanners aimed at 3D printing.
