# Driver/runtime comparison

This document explains what Remold is trying to optimize and what it is **not** claiming.

## Terminology

On Linux, Remold is a **userspace driver/runtime** built on libusb. It is not an authored kernel USB driver.

Using libusb itself is not unique: OpenKinect/libfreenect is also a userspace Kinect driver using libusb. Remold's differentiator is the surrounding runtime architecture and project-specific ownership policy.

## Comparison

| Area | Remold Linux | OpenKinect/libfreenect | Linux `gspca_kinect` | SensorKinect/OpenNI 1.x |
| --- | --- | --- | --- | --- |
| Primary goal | managed Kinect runtime for Remold/robotics | generic Kinect v1 userspace library | V4L2 camera integration in kernel | OpenNI middleware sensor module |
| Camera transport | direct libusb | libusb | kernel USB/GSPCA | userspace stack |
| RGB | yes | yes | yes | yes |
| IR | yes | yes | yes | yes |
| Depth | yes | yes | depth mode | yes |
| RGB/Depth concurrent policy | managed by runtime | exposed to library user | not the same multi-client runtime model | middleware-dependent |
| Motor/LED/accelerometer | yes | yes | camera driver does not provide full Remold device stack | historically partial/stack-specific |
| Four-mic runtime | firmware bootstrap + ALSA | supported with firmware path | outside camera driver | older stack-specific |
| Multi-application ownership | one Remold owner + fan-out IPC | normally application/library ownership | V4L2 semantics | older client/server limitations vary |
| Hot-plug service policy | udev + systemd + retry loops | application responsibility plus udev setup | kernel/V4L2 device lifecycle | older middleware lifecycle |
| V4L2 webcam output | managed loopback bridge | application may build its own | native camera node | not its primary Linux interface |
| Remold Scanner/Audio ABI | native | no | no | no |
| Maturity | experimental/new | mature community project | mature kernel component | historical |

## Where Remold gains control

### 1. No `libfreenect.so` runtime dependency

The Linux Remold camera executable owns its Kinect protocol code and links directly to `libusb-1.0`. This removes a middleware layer from the deployed runtime and lets this project fix its own stream/recovery behavior.

This does **not** mean Remold invented the Kinect protocol. Public OpenKinect work and the Linux Kinect driver are important technical references and are credited in the repository notices.

### 2. Central hardware ownership

Instead of each program opening the Kinect independently, Scanner, Surveillance, V4L2, IP Camera, Microphones and Acoustic Scanner consume a managed runtime. This lets one place enforce RGB/IR exclusion, share depth, fan out audio and coordinate reconnects.

### 3. Robotics-oriented lifecycle

The runtime is designed for `ONLINE → unplugged → retry → ONLINE` behavior rather than requiring an operator to restart every application after a cable event.

### 4. Stable application boundary

The Processing tools speak Remold protocols. They do not embed Linux libusb/ALSA knowledge or Windows WinUSB/WASAPI knowledge. This makes additional native backends possible later without rewriting application logic.

## Where mature alternatives are ahead

Remold should not currently be described as more mature or more broadly compatible than libfreenect or the kernel driver.

Those projects have years of real-hardware exposure across USB controllers, Kinect revisions, distributions and unusual failure conditions. Remold still needs a systematic physical-device validation matrix.

For applications that only need a conventional Linux camera device, `gspca_kinect` may be simpler. For software already written to the libfreenect API, libfreenect remains the natural compatibility choice.

## References

- OpenKinect/libfreenect: https://github.com/OpenKinect/libfreenect
- Linux `gspca_kinect`: https://github.com/torvalds/linux/blob/master/drivers/media/usb/gspca/kinect.c
- SensorKinect: https://github.com/avin2/SensorKinect
