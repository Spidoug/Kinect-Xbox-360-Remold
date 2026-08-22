# Remold Audio Firmware (clean-room, experimental)

This directory starts an independent runtime firmware for Kinect Xbox 360 model 1414 audio hardware. It is **not flashed by the normal BUILD.cmd**. The current production path remains Microsoft UACFirmware + inbox USB Audio/WASAPI until the hardware backend is proven.

## Implemented now

- portable 4-channel 16 kHz DSP core;
- GCC-PHAT / SRP-style horizontal direction scan over -90..+90 degrees;
- Kinect v1 microphone geometry: 149 mm, 40 mm, 37 mm spacing (226 mm aperture);
- exponentially accumulated acoustic occupancy panorama;
- active-echo matched-filter engine with sparse azimuth/range reflector output;
- a defined 1–7 kHz, 8 ms probe waveform for a synchronized external emitter;
- clean-room firmware HAL with no guessed MMIO;
- provisional USB/vendor protocol and descriptor skeleton;
- reference-firmware analyzer that reports information but never modifies firmware;
- host self-test for the DSP.

## Physical limits

Four microphones in a horizontal linear array primarily resolve horizontal direction. Passive audio can localize active sound sources and build an acoustic activity panorama, but cannot reconstruct a static 3D room mesh. Active echo mode can estimate horizontal bearing plus range to strong reflectors when a synchronized acoustic emitter is available. Elevation remains poorly observable without another non-collinear microphone baseline or sensor fusion.

## Hardware bring-up gates

The firmware application is intentionally wired to `hal_unresolved.c`. Before real hardware execution, reverse engineering must establish:

1. exact CPU executing the uploaded image and startup state;
2. RAM/stack/vector layout;
3. USB controller registers/FIFO constraints;
4. audio ADC/codec interface and DMA layout;
5. interrupt controller and clocks;
6. how the TAS1020B USB-audio controller and the larger ARM-side firmware divide responsibility.

No MMIO address is guessed in this tree.

## Test the DSP on a workstation

```text
python tests/run_host_tests.py
```

The same C files are intended to be compiled first on the host, then on the identified embedded target.

On the Windows build machine used by the main project, the same DSP test can be compiled with the installed Visual Studio toolchain by running:

```text
TEST-DSP.cmd
```

This does not connect to or flash the Kinect.

## DSP memory budget

The current floating-point reference engine uses roughly 30 KiB of working state for spectra/correlations. Active echo mode additionally expects a 4 x 2048 x 32-bit capture history (32 KiB) supplied by the capture layer. This is intentionally an ARM-side/reference implementation; it is not intended for the TAS1020B 8052 RAM. After the processor/RAM map is confirmed, the same algorithm can be converted to fixed-point and scratch buffers can be overlaid or placed in external RAM.
