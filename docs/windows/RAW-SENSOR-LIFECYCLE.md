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

## Studio handshake fix

ScannerPort `Reply` is 68 bytes. Surveillance now consumes all 68 bytes. The previous 32-byte read left 36 bytes in the named pipe, which could be mistaken for the next frame header and corrupt RGB/IR streaming after a module open/close/reopen sequence.

## V1 ABI boundary

Protocol version 1 accepts only the four sensor-native ScannerPort payloads documented above. NV12 RGB, Gray16 IR and unpacked Depth are not ScannerPort formats and have no parser or negotiation path in SynKinect Studio. A mismatched pixel format, payload length, magic or version is a protocol error, not a signal to select an older decoder.

Windows and Linux expose the same RAW camera concept. Conversion exists only after the ScannerPort boundary: inside SynKinect Studio for application processing, or inside an explicit operating-system/network adapter that must produce NV12, YUYV or JPEG.
