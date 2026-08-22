# SynKinect Acoustic Scanner

Processing visualization for the Kinect Xbox 360 four-microphone array. It connects to the dedicated `\\.\pipe\Kinect360RemoldAcoustic` fan-out pipe, so it can run at the same time as `SynKinectMicrophones` without competing for the raw-audio client slot.

The live mode is passive horizontal localization. It mirrors the clean-room firmware DSP model: four channels at 16 kHz, 256-sample windows, 512-point FFT, six microphone pairs, GCC-PHAT cross-correlations, SRP-style steering from -90° to +90°, fractional-lag interpolation, peak refinement and a decaying acoustic-occupancy map.

The four Kinect microphones form an essentially linear 226 mm aperture, so this view estimates horizontal azimuth rather than full elevation/3D geometry. Active echo/range visualization remains reserved for the custom-firmware plus synchronized external-emitter path.

The source owns its pipe lifecycle. Closing or killing Processing releases only this acoustic client. On a stale session the sketch closes the handle and re-subscribes automatically.



## Transport recovery

The scanner prefers the independent `\\.\pipe\Kinect360RemoldAcoustic` fan-out and retries that preferred endpoint for the bounded `transport.pipeOpenAttempts` / `transport.pipeOpenRetryMs` window before considering a fallback. If that pipe is absent because Windows is still running an older AudioBridge binary, it can temporarily subscribe to `\\.\pipe\Kinect360RemoldAudio` when `transport.allowMonitorPipeFallback=true`. The UI identifies whether the current session is using the dedicated or shared fallback pipe. The fallback cannot share the single legacy monitor instance with SynKinectMicrophones, so reinstalling the current driver package is still the preferred path because it forces the current AudioBridge service binary to be staged and installed.
