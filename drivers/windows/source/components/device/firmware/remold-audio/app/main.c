#include "../include/remold_audio_hal.h"
#include "../include/remold_acoustic_scan.h"
#include "../dsp/remold_scan_internal.h"

/* This is the clean-room application shell. It is intentionally impossible to
 * flash in the current tree because the hardware backend is unresolved. That
 * prevents guessed MMIO from being executed on a real Kinect.
 */
int remold_firmware_main(void) {
    RemoldScanConfig cfg;
    RemoldScanEngine engine;
    int32_t frame[REMOLD_SCAN_CHANNELS][REMOLD_SCAN_FRAME_SAMPLES];
    RemoldScanFrame scan;

    remold_scan_default_config(&cfg);
    remold_scan_init(&engine, &cfg);

    if (g_remold_audio_hal.clock_init() != 0) return 10;
    if (g_remold_audio_hal.codec_init(cfg.sample_rate_hz) != 0) return 11;
    if (g_remold_audio_hal.usb_init() != 0) return 12;
    if (g_remold_audio_hal.capture_start() != 0) return 13;

    for (;;) {
        if (g_remold_audio_hal.capture_read(frame) == 0) {
            remold_scan_process(&engine, frame, &scan);
            (void)g_remold_audio_hal.usb_publish_scan(&scan);
        }
        (void)g_remold_audio_hal.usb_poll();
    }
}
