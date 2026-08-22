# Direct libusb Kinect 1414 backend

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

- 640×480;
- Bayer mosaic;
- 30 fps target;
- converted inside Remold before publishing to application clients.

### Infrared

- physical stream height: 488 lines;
- packed 10-bit samples;
- unpacked to 16-bit grayscale storage;
- Remold application ABI publishes the 640×480 image region expected by the existing tools.

### Depth

- 640×480;
- packed 11-bit shift values;
- converted to millimeters only when factory calibration is available.

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

The backend requests zero-plane and constant-shift parameters from the sensor and constructs a raw-shift-to-millimeter table.

If calibration cannot be read, the backend deliberately does not publish raw disparity under a `DepthMm16` claim. The frame calibration flag remains clear and metric depth values are withheld.

## Demosaic and unpack validation

The source contains dedicated conversion paths for Bayer RGB, packed 10-bit IR and packed 11-bit depth. Development validation included round-trip test vectors for the packed 10/11-bit bitstream logic and strict compiler warnings.

Physical USB timing and image correctness still require a real Kinect validation matrix; see `docs/PROJECT-STATUS.md`.
