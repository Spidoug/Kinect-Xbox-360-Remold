# Acoustic Scanner — V1

SynKinect Studio's Acoustic Scanner is a real-time four-microphone localization and spatial-audio module for Kinect Xbox 360 1414/1473.

## Signal path

The native audio runtime owns one physical Kinect USB Audio capture session and publishes raw 4-channel S32LE/16 kHz frames to the Studio. Every 256-sample block is processed by the acoustic worker; analysis is not tied to the UI frame rate.

The DOA stage removes DC, applies a Hann window and evaluates GCC-PHAT/TDOA pair correlations across all six microphone pairs. The measured Kinect v1 horizontal channel coordinates are used to score candidate azimuths from -90° to +90°. A near-field x/z grid then evaluates the same pairwise delays to provide an approximate horizontal source position.

The array is linear, so azimuth is the primary observability. The x/z position is an acoustic estimate and is not a metrology-grade 3D coordinate.

## Beamforming

The output stage uses fractional-delay delay-and-sum beamforming:

- **AUTO** follows a sufficiently confident DOA estimate and smooths steering between blocks.
- **MANUAL** lets the user click the radar to choose the steering azimuth.

The beamformed mono stream is written to the current Java/Windows playback output at 16 kHz/16-bit. The four raw microphone channels remain unchanged for diagnostics and DOA/TDOA processing.

## Runtime ownership

Windows uploads Microsoft Kinect UAC firmware through `045E:02AD`; after re-enumeration, `045E:02BB/02C3&MI_02` stays on the inbox USB Audio stack and is captured by WASAPI. The runtime enumerates all active Kinect MI_02 capture endpoints and fails over between compatible endpoints instead of pinning permanently to the first stale endpoint.

Linux uses the equivalent UAC re-enumeration and ALSA capture. In both systems the native bridge fans the raw capture to independent Microphones and Acoustic Scanner consumers so the Studio modules never compete for the physical capture handle.
