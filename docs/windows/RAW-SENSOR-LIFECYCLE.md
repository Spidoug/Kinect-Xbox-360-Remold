# Raw sensor transport and reopen-safe lifecycle

SynKinect Studio 1.0 keeps the physical Kinect USB session independent from the lifetime of individual Studio modules.

## ScannerPort payloads on Windows

- RGB VGA: sensor-native GRBG8 Bayer, 640×480.
- RGB HQ: sensor-native GRBG8 Bayer, 1280×1024.
- Infrared: sensor-native packed 10-bit payload, 640×488. SynKinect Studio unpacks it and crops the four sensor rows above and below the 640×480 image.
- Depth: sensor-native packed 11-bit shift payload, 640×480. SynKinect Studio unpacks it and applies the per-device factory calibration negotiated in the 68-byte ScannerPort reply.

The Media Foundation virtual camera remains NV12 because that is its Windows-facing contract. Its RGB conversion is isolated from ScannerPort and never controls the physical stream mode.

## Reopen lifecycle

Endpoint 0x81 registers its WinUSB isochronous buffer once per physical camera session. RGB/IR/HQ transitions stop firmware capture, cancel pending reads, reconfigure the sensor and requeue on the same registered buffer. Normal module switching does not unregister or reset the endpoint.

Endpoint 0x82 is armed on the first real Depth request and its WinUSB isochronous registration remains alive until the physical camera session ends. When there is no Depth or IR consumer, register 0x06 is turned off but pending host reads and the registered buffer are retained. A later Depth module therefore resumes on the existing transport instead of recreating the endpoint.

A genuine USB timeout or stuck transfer still performs endpoint-local recovery: the affected endpoint is cancelled/unregistered and rebuilt. No device-wide reset is used for a normal Studio module handoff.

Model 1473 startup waits up to five seconds for the post-firmware audio/control sibling and issues its semantic LED keep-alive. Isochronous fixed-size streams use a five-packet recovery window. Missing or short payload regions are cleared before a frame is published, avoiding stale pixels while preserving RGB, IR and Depth cadence on a busy USB 2 controller.

Camera ISO work uses eight transfers with 32 packets each. The first `WinUsb_ReadIsochPipeAsap` request uses `ContinueStream=FALSE` to establish the start frame; the other seven and all replacements use `TRUE`, extending one ordered schedule without overlapping ASAP frame ranges. Non-disconnect completion errors are resubmitted and an idle transfer is not destroyed merely because three seconds elapsed. The selected alternate setting, endpoint geometry and runtime failures are recorded in `%ProgramData%\Kinect360Remold\camera-bridge.log`.

## Studio handshake fix

ScannerPort `Reply` is 68 bytes and every consumer must read all 68 bytes. Partial reply reads leave bytes in the named pipe and can corrupt the next RGB/IR frame header after a module open/close/reopen sequence.

## V1 ABI boundary

Protocol version 1 accepts only the four sensor-native ScannerPort payloads documented above. NV12 RGB, Gray16 IR and unpacked Depth are not ScannerPort formats and have no parser or negotiation path in SynKinect Studio. A mismatched pixel format, payload length, magic or version is a protocol error, not a signal to select an older decoder.

Windows and Linux expose the same RAW camera concept. Conversion exists only after the ScannerPort boundary: inside SynKinect Studio for application processing, or inside an explicit operating-system/network adapter that must produce NV12, YUYV or JPEG.
