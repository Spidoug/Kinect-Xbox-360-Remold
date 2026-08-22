# Acoustic environment scanning

## Passive mode

Each 256-sample, four-channel frame is DC-removed, Hann-windowed and transformed with a 512-point FFT. The steering stage is an SRP-PHAT/GCC-PHAT implementation. For each of the six microphone pairs, the engine builds a PHAT-weighted cross spectrum and inverse-transforms it to a generalized cross-correlation. A horizontal steering scan from -90 to +90 degrees evaluates the correlation at the predicted fractional delay of every pair. Pair scores are summed, normalized, peak-refined and accumulated into a decaying acoustic occupancy panorama.

The model uses the Kinect v1 geometry (left-to-right spacing 149 mm, 40 mm, 37 mm; total aperture 226 mm) and defaults to 343 m/s sound speed. Sound speed is configurable because temperature materially changes TDOA calibration.

Passive output is an **acoustic activity map**, not room geometry. A quiet wall does not emit enough information to be localized passively.

## Active echo mode

The firmware defines a Hann-enveloped 1–7 kHz linear-FM probe of 128 samples (8 ms at 16 kHz). A synchronized external emitter reproduces that waveform while firmware marks sample zero. The engine first estimates horizontal direction, delay-and-sum beamforms toward that direction, and then matched-filters the 2048-sample history. Local correlation peaks become sparse reflector points `(azimuth, range, strength, confidence)` using `range = c * round_trip_delay / 2`.

This produces a coarse **2D horizontal polar reflection map**. The four microphones are essentially collinear, so elevation is fundamentally weak/ambiguous. A full 3D acoustic mesh would require a second non-collinear aperture, mechanical motion that changes baseline geometry, or fusion with the Kinect depth camera.

## Practical resolution

At 16 kHz, one sample corresponds to about 21.4 mm of one-way sound travel, or about 10.7 mm of idealized round-trip range. Real spatial resolution is substantially worse because of the limited 1–7 kHz bandwidth, reverberation, speaker/microphone response and fractional-delay estimation. The code therefore reports confidence and sparse reflectors rather than claiming centimeter-accurate room geometry.


## Processing live view

`applications/processing/SynKinectAcousticScanner` is the host-side live visualization of the passive four-microphone scan. AudioBridge publishes a dedicated `\\.\pipe\Kinect360RemoldAcoustic` copy of the same 4-channel/16 kHz/S32LE stream used by the microphone monitor, so both sketches can run simultaneously. The Processing engine mirrors the 512-point, six-pair GCC-PHAT/SRP steering model and maintains a -90°..+90° horizontal occupancy map. Active echo/range rendering remains gated on the clean-room firmware plus synchronized external emitter.
