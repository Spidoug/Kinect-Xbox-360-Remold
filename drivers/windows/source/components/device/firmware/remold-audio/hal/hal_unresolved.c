#include "../include/remold_audio_hal.h"

static int unavailable(void) { return -1; }
static int unavailable_rate(uint32_t rate) { (void)rate; return -1; }
static int unavailable_capture(int32_t frame[REMOLD_SCAN_CHANNELS][REMOLD_SCAN_FRAME_SAMPLES]) { (void)frame; return -1; }
static int unavailable_scan(const RemoldScanFrame* frame) { (void)frame; return -1; }
static int unavailable_echo(const RemoldEchoFrame* frame) { (void)frame; return -1; }

RemoldAudioHal g_remold_audio_hal = {
    unavailable,
    unavailable_rate,
    unavailable,
    unavailable_capture,
    unavailable,
    unavailable,
    unavailable_scan,
    unavailable_echo
};
