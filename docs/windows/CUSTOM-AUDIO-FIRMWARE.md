# Clean-room Kinect audio firmware

The Remold project now contains an experimental independent firmware tree at `components/device/firmware/remold-audio/`. The normal driver build does not flash it.

Public teardown evidence identifies a TI TAS1020B in the Kinect v1 USB-audio path. The TAS1020B itself uses an 8052-class controller and has very little application RAM. Historical OpenKinect analysis also reports ARM-like code in `audios.bin`/`2bl.bin`, which implies that the complete Kinect audio runtime cannot safely be modeled as “one 8052 firmware”. The project therefore separates the hardware frontend from a portable DSP core while the exact division of responsibility is reverse engineered.

The first hardware milestone is intentionally small: execute independent code and enumerate a diagnostic USB vendor interface. UAC streaming and microphone capture come only after MMIO, DMA and codec paths are confirmed.
