#include "remold_scan_internal.h"
#include <math.h>
#include <string.h>

#ifndef REMOLD_PI
#define REMOLD_PI 3.14159265358979323846f
#endif

static const RemoldPair kPairs[REMOLD_PAIR_COUNT] = {
    {0,1},{0,2},{0,3},{1,2},{1,3},{2,3}
};

static float clampf_local(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static float corr_at_lag(const float* corr, float lag) {
    /* Correlation is stored circularly by IFFT. Positive/negative fractional
     * lags are mapped into [0,N). Linear interpolation substantially reduces
     * the 16 kHz integer-delay stair-step without requiring a larger FFT.
     */
    float wrapped = lag;
    while (wrapped < 0.0f) wrapped += (float)REMOLD_SCAN_FFT_SIZE;
    while (wrapped >= (float)REMOLD_SCAN_FFT_SIZE) wrapped -= (float)REMOLD_SCAN_FFT_SIZE;
    int i0 = (int)floorf(wrapped);
    int i1 = (i0 + 1) % (int)REMOLD_SCAN_FFT_SIZE;
    float f = wrapped - (float)i0;
    return corr[i0] * (1.0f - f) + corr[i1] * f;
}

void remold_scan_default_config(RemoldScanConfig* config) {
    memset(config, 0, sizeof(*config));
    config->sample_rate_hz = REMOLD_ECHO_SAMPLE_RATE_HZ;
    config->sound_speed_mps = 343.0f;
    config->occupancy_decay = 0.92f;
    config->minimum_rms = 0.0025f;
    config->echo_threshold = 0.30f;
    config->echo_min_range_m = 0.20f;
    config->echo_max_range_m = 6.00f;
    config->geometry.x_m[0] = -0.113f;
    config->geometry.x_m[1] =  0.036f;
    config->geometry.x_m[2] =  0.076f;
    config->geometry.x_m[3] =  0.113f;
}

void remold_scan_init(RemoldScanEngine* engine, const RemoldScanConfig* config) {
    memset(engine, 0, sizeof(*engine));
    if (config) engine->config = *config;
    else remold_scan_default_config(&engine->config);
    if (engine->config.sample_rate_hz == 0) engine->config.sample_rate_hz = 16000u;
    if (engine->config.sound_speed_mps < 250.0f) engine->config.sound_speed_mps = 343.0f;
    engine->config.occupancy_decay = clampf_local(engine->config.occupancy_decay, 0.0f, 0.9999f);
}

void remold_scan_reset(RemoldScanEngine* engine) {
    RemoldScanConfig cfg = engine->config;
    remold_scan_init(engine, &cfg);
}

static void prepare_channel(RemoldScanEngine* engine, unsigned ch,
                            const int32_t samples[REMOLD_SCAN_CHANNELS][REMOLD_SCAN_FRAME_SAMPLES],
                            float* rms_accum) {
    double mean = 0.0;
    for (unsigned i = 0; i < REMOLD_SCAN_FRAME_SAMPLES; ++i)
        mean += (double)samples[ch][i];
    mean /= (double)REMOLD_SCAN_FRAME_SAMPLES;

    for (unsigned i = 0; i < REMOLD_SCAN_FFT_SIZE; ++i) {
        engine->spectra[ch][i].re = 0.0f;
        engine->spectra[ch][i].im = 0.0f;
    }

    for (unsigned i = 0; i < REMOLD_SCAN_FRAME_SAMPLES; ++i) {
        const float x = (float)(((double)samples[ch][i] - mean) / 2147483648.0);
        const float w = 0.5f - 0.5f * cosf((2.0f * REMOLD_PI * (float)i) /
                                           (float)(REMOLD_SCAN_FRAME_SAMPLES - 1u));
        const float v = x * w;
        engine->spectra[ch][i].re = v;
        *rms_accum += v * v;
    }
    remold_fft(engine->spectra[ch], REMOLD_SCAN_FFT_SIZE, 0);
}

static void build_pair_correlations(RemoldScanEngine* engine) {
    for (unsigned p = 0; p < REMOLD_PAIR_COUNT; ++p) {
        const unsigned a = kPairs[p].a;
        const unsigned b = kPairs[p].b;
        RemoldComplex cross[REMOLD_SCAN_FFT_SIZE];
        for (unsigned k = 0; k < REMOLD_SCAN_FFT_SIZE; ++k) {
            const RemoldComplex x = engine->spectra[a][k];
            const RemoldComplex y = engine->spectra[b][k];
            /* X_a * conj(X_b) */
            const float re = x.re * y.re + x.im * y.im;
            const float im = x.im * y.re - x.re * y.im;
            const float mag = sqrtf(re * re + im * im);
            const float inv = 1.0f / (mag + 1.0e-12f);
            cross[k].re = re * inv;
            cross[k].im = im * inv;
        }
        remold_fft(cross, REMOLD_SCAN_FFT_SIZE, 1);
        for (unsigned i = 0; i < REMOLD_SCAN_FFT_SIZE; ++i)
            engine->pair_corr[p][i] = cross[i].re;
    }
}

void remold_scan_process(RemoldScanEngine* engine,
                         const int32_t samples[REMOLD_SCAN_CHANNELS][REMOLD_SCAN_FRAME_SAMPLES],
                         RemoldScanFrame* output) {
    memset(output, 0, sizeof(*output));
    float rms_accum = 0.0f;
    for (unsigned ch = 0; ch < REMOLD_SCAN_CHANNELS; ++ch)
        prepare_channel(engine, ch, samples, &rms_accum);
    output->rms = sqrtf(rms_accum /
                        (float)(REMOLD_SCAN_CHANNELS * REMOLD_SCAN_FRAME_SAMPLES));

    build_pair_correlations(engine);

    float min_score = 1.0e30f;
    float max_score = -1.0e30f;
    unsigned peak_bin = 0;
    for (unsigned bin = 0; bin < REMOLD_SCAN_AZIMUTH_BINS; ++bin) {
        const float deg = (float)(REMOLD_SCAN_AZIMUTH_MIN_DEG + (int)bin);
        const float s = sinf(deg * REMOLD_PI / 180.0f);
        float score = 0.0f;
        for (unsigned p = 0; p < REMOLD_PAIR_COUNT; ++p) {
            const unsigned a = kPairs[p].a;
            const unsigned b = kPairs[p].b;
            const float dx = engine->config.geometry.x_m[b] - engine->config.geometry.x_m[a];
            /* Positive azimuth follows increasing geometry.x_m. Synthetic tests lock this convention. */
            const float lag = dx * s * (float)engine->config.sample_rate_hz /
                              engine->config.sound_speed_mps;
            score += corr_at_lag(engine->pair_corr[p], lag);
        }
        output->directional[bin] = score;
        if (score < min_score) min_score = score;
        if (score > max_score) { max_score = score; peak_bin = bin; }
    }

    const float span = max_score - min_score;
    float second = 0.0f;
    for (unsigned bin = 0; bin < REMOLD_SCAN_AZIMUTH_BINS; ++bin) {
        float normalized = span > 1.0e-9f ? (output->directional[bin] - min_score) / span : 0.0f;
        output->directional[bin] = normalized;
        if (bin + 3u < peak_bin || bin > peak_bin + 3u) {
            if (normalized > second) second = normalized;
        }
        const float injection = output->rms >= engine->config.minimum_rms ?
                                normalized * clampf_local(output->rms * 8.0f, 0.0f, 1.0f) : 0.0f;
        engine->occupancy[bin] = engine->config.occupancy_decay * engine->occupancy[bin] +
                                 (1.0f - engine->config.occupancy_decay) * injection;
        output->occupancy[bin] = engine->occupancy[bin];
    }

    float refined = (float)(REMOLD_SCAN_AZIMUTH_MIN_DEG + (int)peak_bin);
    if (peak_bin > 0 && peak_bin + 1 < REMOLD_SCAN_AZIMUTH_BINS) {
        const float y0 = output->directional[peak_bin - 1];
        const float y1 = output->directional[peak_bin];
        const float y2 = output->directional[peak_bin + 1];
        const float d = (y0 - 2.0f * y1 + y2);
        if (fabsf(d) > 1.0e-6f)
            refined += clampf_local(0.5f * (y0 - y2) / d, -0.5f, 0.5f);
    }

    output->frame_number = engine->frame_number++;
    output->peak_azimuth_deg = refined;
    output->peak_score = output->directional[peak_bin];
    output->confidence = clampf_local(output->peak_score - second, 0.0f, 1.0f);
}
