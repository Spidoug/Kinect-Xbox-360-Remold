# Kinect 1414 audio hardware map — confirmed vs unresolved

## Confirmed externally

- USB boot identity: Microsoft `045E:02AD`.
- Boot transport exposes bulk `0x01 OUT` and `0x81 IN`.
- Public upload traces write runtime payload beginning at `0x00080000` and then execute it.
- Kinect v1 contains a TI TAS1020B USB streaming controller. TI documents that part as USB Audio 1.0 capable and based on an 8052 core.
- The microphone path includes two-channel ADC hardware; four physical microphones are delivered as four synchronized 16 kHz channels in known Kinect audio runtimes.
- Historical OpenKinect analysis reports ARM-like instruction patterns in `audios.bin` and `2bl.bin`.

## Therefore not assumed

The project does **not** assume that the uploaded `audios.bin` payload executes directly on the TAS1020B 8052. The address range and ARM evidence are inconsistent with treating the whole Kinect audio stack as a single 8052 application. A second processor/firmware layer or controller relationship must be mapped experimentally.

## Required before hardware firmware is enabled

- CPU core and reset/entry ABI for uploaded payload;
- executable RAM bounds and stack placement;
- interrupt/vector state;
- clock tree;
- ADC/codec register path;
- audio DMA/FIFO ownership;
- USB endpoint/FIFO ownership;
- communication path between the larger processor and TAS1020B;
- safe recovery behavior after a bad runtime image.

Until those are confirmed, `hal_unresolved.c` is the only hardware backend and normal `BUILD.cmd` continues to use the known UAC runtime.

## DSP placement constraint

The current SRP-PHAT reference needs tens of kilobytes of working memory and therefore cannot execute inside the TAS1020B's small 8052 application RAM. Hardware bring-up must identify the ARM-side/external-RAM execution environment before enabling the embedded scanner.
