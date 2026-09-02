# Direct libusb Kinect 1414/1473 backend

## Purpose

`drivers/linux/source/src/kinect_usb_camera.cpp` implements the Kinect v1 camera transport directly on libusb-1.0. The Linux camera runtime does not link to `libfreenect.so`.

The implementation was cross-checked against public Kinect v1 behavior in OpenKinect/libfreenect and the Linux kernel `gspca_kinect` driver. Those projects remain important references; Remold's contribution is its own runtime integration, policy and application boundary.

## USB identity and streams

The Xbox 360 Kinect camera is normally exposed as `045e:02ae`.

The runtime claims camera interface 0 and uses the Kinect stream endpoints:

```text
0x81 → RGB or infrared
0x82 → depth
```

Control transfers configure the sensor registers and stream modes.

## Physical formats

### RGB

- 640×480 GRBG8 Bayer for VGA;
- 1280×1024 GRBG8 Bayer for HQ;
- 30 fps target for VGA;
- Bayer bytes are published unchanged on ScannerPort.

### Infrared

- physical stream height: 488 lines;
- packed 10-bit samples;
- the packed sensor bytes are published unchanged on ScannerPort;
- SynKinect Studio performs unpacking and the 488→480 crop.

### Depth

- 640×480;
- packed 11-bit shift values;
- the packed sensor bytes are published unchanged on ScannerPort;
- SynKinect Studio unpacks shift codes and converts them to millimetres only when factory calibration is available.

## Packet framing

Kinect isochronous packets include the known `RB` stream header and SOF/MOF/EOF flags. Remold validates stream framing and sequence progression before completing an application frame.

The backend uses multiple asynchronous libusb transfers to keep the isochronous queue populated. A USB removal or transfer failure that cannot be resubmitted invalidates the session instead of silently continuing with a shrinking transfer pool.

## RGB/IR arbitration

Endpoint `0x81` is shared by RGB and IR. Remold therefore models the hardware honestly:

```text
RGB  ─┐
      ├── mutually exclusive
IR   ─┘

Depth ── independent
```

A subscription requesting RGB+IR together is invalid. Depth can be combined with either one.

## Factory depth calibration

The backend requests zero-plane and constant-shift parameters from the sensor and exposes those factory constants in the per-device ScannerPort handshake.

The camera backend publishes the Kinect packed 11-bit sensor payload unchanged. Factory calibration constants are carried in the scanner handshake, and SynKinect Studio performs raw→millimetre conversion. If factory calibration cannot be read, the raw transport still remains valid but Studio marks metric Depth unavailable instead of mislabeling raw values as millimetres.

## Conversion boundary

The libusb camera owner does not demosaic RGB and does not unpack IR or Depth before ScannerPort. SynKinect Studio owns those conversions for application use. Linux V4L2 and IP-camera adapters convert Bayer only at their explicit YUYV/JPEG output boundary. This prevents the native capture layer from silently becoming a second image-processing implementation.

Physical USB timing and image correctness still require a real Kinect validation matrix; requires a real Kinect hardware validation matrix in addition to the source and synthetic checks shipped here.
