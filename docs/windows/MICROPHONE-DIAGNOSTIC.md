# Microphone diagnostic

The NUI Audio boot function (`USB\VID_045E&PID_02AD`) is bound to the Remold Audio INF, whose function driver is Microsoft's `winusb.sys`. AudioBridge uploads Microsoft Kinect SDK UACFirmware in user mode. The boot device should then disappear and `USB\VID_045E&PID_02BB&MI_02` should become an active Windows capture endpoint on the inbox USB Audio class driver.

Check `%ProgramData%\Kinect360Remold\audio-bridge-status.txt`.

Important fields:

- `audio_transport_model=winusb-boot-uac-runtime-wasapi`
- `boot_usb_pid=02ad`
- `runtime_usb_pid=02bb`
- `runtime_capture=wasapi-shared`
- `firmware_kind=Microsoft-Kinect-SDK-UACFirmware`
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
- `uac-endpoint-not-found`: neither the `02BB` capture endpoint nor a usable `02AD` boot transport is currently visible. A physical power-cycle is useful after testing older `audios.bin` firmware because firmware is RAM-resident until power is removed.
- `uac-runtime-error`: Windows exposed the endpoint but WASAPI initialization/capture failed; inspect the capture format fields.
- `uac-runtime-capturing`: expected steady state. `published_frames` should increase and a Processing subscriber should increase `pipe_frames`.


## Version 1 service lifetime

The AudioBridge is a Win32 user-mode service installed beside the WinUSB boot package. The INF remains `SERVICE_DEMAND_START` for PnP-safe installation, but Install/Repair promotes the service to delayed automatic start through the Service Control Manager and configures restart-on-failure. The INF uses `SPSVCINST_NOCLOBBER_STARTTYPE` so a later device reinstall does not overwrite that runtime policy. This is important because the boot interface `02AD` disappears after UACFirmware starts and the active microphone endpoint becomes `02BB`; the raw Processing pipes must outlive that identity change.

`SynKinectMicrophones` prefers `\\.\pipe\Kinect360RemoldAudio`. If that pipe is temporarily busy/unavailable, `transport.allowAcousticPipeFallback=true` permits the same four-channel ABI to be consumed from `\\.\pipe\Kinect360RemoldAcoustic`. The UI shows which pipe is active.


## Named-pipe connection reliability

The AudioBridge uses overlapped `ConnectNamedPipe`. Its completion path must always pass a valid transferred-byte storage pointer to `GetOverlappedResult`; using a null pointer can make an otherwise valid asynchronous client connection fail before the protocol handshake. The driver keeps independent monitor and acoustic pipes, and both Processing clients retry their preferred endpoint briefly before using the compatible fallback.

