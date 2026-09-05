# Microphone diagnostic

The NUI Audio boot function (`USB\VID_045E&PID_02AD`) is bound to the Remold Audio INF, whose function driver is Microsoft's `winusb.sys`. AudioBridge uploads Microsoft Kinect Runtime v1.8 UACFirmware 01.02.709.00 in user mode. The boot device should then disappear and `USB\VID_045E&PID_02BB&MI_02` or `USB\VID_045E&PID_02C3&MI_02` should become an active Windows capture endpoint on the inbox USB Audio class driver.

Check `%ProgramData%\Kinect360Remold\audio-bridge-status.txt`.

Important fields:

- `audio_transport_model=winusb-boot-uac-runtime-wasapi`
- `boot_usb_pid=02ad`
- `runtime_usb_pid_family=02bb,02c3`
- `runtime_capture=wasapi-raw-four-channel`
- `firmware_kind=Microsoft-Kinect-Runtime-1.8-UACFirmware`
- `firmware_version=01.02.709.00`
- `firmware_bytes`, `firmware_uploads`, `firmware_failures`
- `endpoint_name`
- `capture_sample_rate`, `capture_channels`, `capture_bits`, `capture_format_tag`
- `wasapi_packets`, `wasapi_frames`, `wasapi_silent_frames`, `wasapi_discontinuities`
- `published_frames`, `pipe_clients`, `pipe_frames`
- current `stage` and `last_error`

Interpretation:

- `uac-firmware-uploading`: `02AD` is open and the UAC bootloader transfer is in progress.
- `uac-firmware-error`: bulk bootloader handshake/upload failed; inspect `last_error` and verify the device is still `02AD` on WinUSB.
- `uac-firmware-launched`: launch command succeeded and the bridge is waiting for Windows to enumerate the UAC runtime.
- `uac-endpoint-not-found`: neither the `02BB/02C3` capture endpoint nor a usable `02AD` boot transport is currently visible. Power-cycle the Kinect if the firmware state is uncertain because the audio firmware is RAM-resident until power is removed.
- `uac-runtime-error`: Windows exposed the endpoint but WASAPI initialization/capture failed; inspect the capture format fields.
- `uac-runtime-capturing`: expected steady state. `published_frames` should increase and a Processing subscriber should increase `pipe_frames`.


## Version 1 service lifetime

AudioBridge is a persistent Win32 product runtime, not merely a side effect of the transient `02AD` boot INF. Install/Reinstall copies the current built executable to `%ProgramFiles%\Kinect Xbox 360 Remold`, creates or reconfigures the service even when the Kinect is already in post-firmware `02BB/02C3`, reapplies that persistent `ImagePath` after any `02AD` INF binding, uses delayed automatic start, and configures restart-on-failure. The INF can still create/start the same service when `02AD` is present, but Microphones/Acoustic no longer depend on physically power-cycling the Kinect just to recreate the raw-audio service. This is essential because UAC firmware is RAM-resident and `02AD` disappears after firmware launch.

The **Microphones** tab in `SynKinectStudio` uses only `\\.\pipe\Kinect360RemoldAudio`. V1 does not borrow the Acoustic Scanner endpoint when the canonical monitor endpoint is unavailable; the client reports reconnecting until the correct endpoint returns.


## Named-pipe connection reliability

The AudioBridge uses overlapped `ConnectNamedPipe`. Its completion path must always pass a valid transferred-byte storage pointer to `GetOverlappedResult`; using a null pointer can make an otherwise valid asynchronous client connection fail before the protocol handshake. V1 publishes one canonical multi-client raw-audio endpoint, `\\.\pipe\Kinect360RemoldAudio`; Microphones and Acoustic open independent client sessions on that same latest-frame bus, so one module does not own or starve the other.

