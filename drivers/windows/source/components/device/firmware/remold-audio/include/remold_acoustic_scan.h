#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define REMOLD_SCAN_CHANNELS 4u
#define REMOLD_SCAN_FRAME_SAMPLES 256u
#define REMOLD_SCAN_FFT_SIZE 512u
#define REMOLD_SCAN_AZIMUTH_MIN_DEG (-90)
#define REMOLD_SCAN_AZIMUTH_MAX_DEG 90
#define REMOLD_SCAN_AZIMUTH_BINS 181u
#define REMOLD_SCAN_MAX_REFLECTORS 8u
#define REMOLD_ECHO_HISTORY_SAMPLES 2048u
#define REMOLD_ECHO_TEMPLATE_SAMPLES 128u
#define REMOLD_ECHO_SAMPLE_RATE_HZ 16000u
#define REMOLD_ECHO_START_HZ 1000.0f
#define REMOLD_ECHO_END_HZ 7000.0f

/* Kinect v1 geometry, left-to-right distances 149 mm, 40 mm, 37 mm.
 * Coordinates are centered around the 226 mm aperture midpoint.
 */
typedef struct RemoldMicGeometry {
    float x_m[REMOLD_SCAN_CHANNELS];
    float y_m[REMOLD_SCAN_CHANNELS];
    float z_m[REMOLD_SCAN_CHANNELS];
} RemoldMicGeometry;

typedef struct RemoldScanConfig {
    uint32_t sample_rate_hz;
    float sound_speed_mps;
    float occupancy_decay;
    float minimum_rms;
    float echo_threshold;
    float echo_min_range_m;
    float echo_max_range_m;
    RemoldMicGeometry geometry;
} RemoldScanConfig;

typedef struct RemoldScanFrame {
    uint64_t frame_number;
    float peak_azimuth_deg;
    float peak_score;
    float confidence;
    float rms;
    float directional[REMOLD_SCAN_AZIMUTH_BINS];
    float occupancy[REMOLD_SCAN_AZIMUTH_BINS];
} RemoldScanFrame;

typedef struct RemoldReflector {
    float azimuth_deg;
    float range_m;
    float strength;
    float confidence;
} RemoldReflector;

typedef struct RemoldEchoFrame {
    uint64_t scan_number;
    uint32_t reflector_count;
    RemoldReflector reflectors[REMOLD_SCAN_MAX_REFLECTORS];
} RemoldEchoFrame;

typedef struct RemoldScanEngine RemoldScanEngine;

void remold_scan_default_config(RemoldScanConfig* config);
void remold_scan_init(RemoldScanEngine* engine, const RemoldScanConfig* config);
void remold_scan_reset(RemoldScanEngine* engine);
void remold_scan_process(RemoldScanEngine* engine,
                         const int32_t samples[REMOLD_SCAN_CHANNELS][REMOLD_SCAN_FRAME_SAMPLES],
                         RemoldScanFrame* output);

/* Active echo mode. The emitted waveform is known to firmware; an external
 * synchronized acoustic emitter is still required. The function consumes a
 * rolling 4-channel history beginning at the emission marker and reports a
 * sparse horizontal polar map (azimuth + range), not a 3D mesh.
 */
void remold_echo_template(float out[REMOLD_ECHO_TEMPLATE_SAMPLES]);
void remold_echo_process(RemoldScanEngine* engine,
                         const int32_t history[REMOLD_SCAN_CHANNELS][REMOLD_ECHO_HISTORY_SAMPLES],
                         RemoldEchoFrame* output);

#ifdef __cplusplus
}
#endif
