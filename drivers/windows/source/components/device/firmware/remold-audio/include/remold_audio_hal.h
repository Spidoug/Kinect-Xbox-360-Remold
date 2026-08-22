#pragma once
#include <stdint.h>
#include "remold_acoustic_scan.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Hardware abstraction for the clean-room runtime. No MMIO address is guessed.
 * reverse/tools must identify each register block before a backend is allowed
 * to report itself as hardware-ready.
 */
typedef struct RemoldAudioHal {
    int (*clock_init)(void);
    int (*codec_init)(uint32_t sample_rate_hz);
    int (*capture_start)(void);
    int (*capture_read)(int32_t frame[REMOLD_SCAN_CHANNELS][REMOLD_SCAN_FRAME_SAMPLES]);
    int (*usb_init)(void);
    int (*usb_poll)(void);
    int (*usb_publish_scan)(const RemoldScanFrame* frame);
    int (*usb_publish_echo)(const RemoldEchoFrame* frame);
} RemoldAudioHal;

extern RemoldAudioHal g_remold_audio_hal;

#ifdef __cplusplus
}
#endif
