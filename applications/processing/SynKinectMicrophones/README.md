# SynKinectMicrophones

Processing application for the four physical Kinect microphones. The UI follows the shared SynKinect panel standard: Segoe UI typography, common dark surfaces/accent roles, four independent microphone panels, one transport panel and grouped Capture / Playback / System actions. The window is resizable.

## Architecture

- `MicrophoneProtocol.pde` — named-pipe frame contract.
- `MicrophoneConfig.pde` + `data/microphones.properties` — bounded runtime tuning.
- `MicrophoneLocalization.pde` + `data/i18n/*.properties` — UTF-8 presentation text.
- `MicrophoneSource.pde` — pipe lifecycle and frame validation.
- `BridgeDiagnostics.pde` — structured native transport counters.
- `AudioPipeline.pde` — WAV recording, monitor, playback and speaker test.
- `MicrophoneUI.pde` — presentation only.

Recording and monitoring share one `MicrophoneSource`. WAV capture preserves 16 kHz, 4-channel S32LE. Monitoring and playback select the dominant valid microphone for local listening and apply bounded playback-only gain; recorded samples are not modified.

The WAV player parses RIFF chunks and validates `fmt ` / `data` instead of assuming a fixed 44-byte header.

## Controls

Keyboard shortcuts remain `R` record, `M` monitor, `P` play, `T` speaker test and `G` language. The same actions are available in grouped UI panels; labels come from the locale catalog.

The application resolves the Windows shared-data root from `ProgramData` and then `ALLUSERSPROFILE`, combines it with the diagnostics directory/file declared in `data/microphones.properties`, and reads the UTF-8 status file. The native bridge and Processing UI are statically checked against the same diagnostics path contract. Detailed transport diagnosis belongs in the native status file rather than permanent paragraphs in the UI.


## Session recovery

The raw-audio source owns its named-pipe lifecycle. A stale session is force-closed after `transport.connectionStaleMs` and then subscribed again. The AudioBridge also verifies the client process behind the pipe, so closing or killing Processing releases the old session reliably. Acoustic scanning uses a separate `\\.\pipe\Kinect360RemoldAcoustic` fan-out and can run simultaneously with this application.


## Connection policy

The Processing monitor first opens `\\.\pipe\Kinect360RemoldAudio` and retries the preferred pipe for the bounded `transport.pipeOpenAttempts` / `transport.pipeOpenRetryMs` window before considering a fallback. If that independent fan-out remains unavailable it can fall back to `\\.\pipe\Kinect360RemoldAcoustic`, which uses the same four-channel S32LE ABI. The installed AudioBridge is normalized to delayed automatic start and service recovery so the pipe remains available after the Kinect firmware changes from the 02AD boot identity to the 02BB USB Audio runtime identity. Set `transport.allowAcousticPipeFallback=false` to force the primary monitor pipe only.
