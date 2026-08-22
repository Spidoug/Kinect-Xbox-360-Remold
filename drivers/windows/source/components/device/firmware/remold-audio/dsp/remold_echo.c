#include "remold_scan_internal.h"
#include <math.h>
#include <string.h>

#ifndef REMOLD_PI
#define REMOLD_PI 3.14159265358979323846f
#endif

typedef struct EchoCandidate {
    unsigned delay;
    float strength;
} EchoCandidate;

void remold_echo_template(float out[REMOLD_ECHO_TEMPLATE_SAMPLES]) {
    /* Short audible linear FM probe, 1.0 kHz -> 7.0 kHz over 8 ms at 16 kHz.
     * A Hann envelope limits clicks and protects the matched filter from edge energy.
     * The emitter is external; firmware defines the waveform and sample-zero marker.
     */
    const float fs = (float)REMOLD_ECHO_SAMPLE_RATE_HZ;
    const float f0 = REMOLD_ECHO_START_HZ;
    const float f1 = REMOLD_ECHO_END_HZ;
    const float n1 = (float)(REMOLD_ECHO_TEMPLATE_SAMPLES - 1u);
    float phase = 0.0f;
    for (unsigned n = 0; n < REMOLD_ECHO_TEMPLATE_SAMPLES; ++n) {
        const float t = (float)n / n1;
        const float f = f0 + (f1 - f0) * t;
        phase += 2.0f * REMOLD_PI * f / fs;
        const float w = 0.5f - 0.5f * cosf(2.0f * REMOLD_PI * t);
        out[n] = sinf(phase) * w;
    }
}

static float normalized_match_i32(const int32_t* signal, const float* templ, unsigned n) {
    float dot = 0.0f, a2 = 0.0f, b2 = 0.0f;
    double mean = 0.0;
    for (unsigned i = 0; i < n; ++i) mean += signal[i];
    mean /= (double)n;
    for (unsigned i = 0; i < n; ++i) {
        const float a = (float)(((double)signal[i] - mean) / 2147483648.0);
        const float b = templ[i];
        dot += a * b;
        a2 += a * a;
        b2 += b * b;
    }
    return dot / (sqrtf(a2 * b2) + 1.0e-12f);
}

static float multi_channel_match(
    const int32_t history[REMOLD_SCAN_CHANNELS][REMOLD_ECHO_HISTORY_SAMPLES],
    unsigned delay,
    const float templ[REMOLD_ECHO_TEMPLATE_SAMPLES]) {
    float sum = 0.0f;
    for (unsigned ch = 0; ch < REMOLD_SCAN_CHANNELS; ++ch)
        sum += fabsf(normalized_match_i32(&history[ch][delay], templ, REMOLD_ECHO_TEMPLATE_SAMPLES));
    return sum / (float)REMOLD_SCAN_CHANNELS;
}

static void insert_candidate(EchoCandidate* list, unsigned* count, unsigned delay, float strength) {
    unsigned pos = *count;
    if (pos < REMOLD_SCAN_MAX_REFLECTORS) {
        list[pos].delay = delay;
        list[pos].strength = strength;
        ++(*count);
    } else {
        unsigned weakest = 0;
        for (unsigned i = 1; i < *count; ++i)
            if (list[i].strength < list[weakest].strength) weakest = i;
        if (strength <= list[weakest].strength) return;
        list[weakest].delay = delay;
        list[weakest].strength = strength;
    }
}

void remold_echo_process(RemoldScanEngine* engine,
                         const int32_t history[REMOLD_SCAN_CHANNELS][REMOLD_ECHO_HISTORY_SAMPLES],
                         RemoldEchoFrame* output) {
    memset(output, 0, sizeof(*output));
    output->scan_number = engine->echo_number++;

    float templ[REMOLD_ECHO_TEMPLATE_SAMPLES];
    remold_echo_template(templ);
    const unsigned scan_limit = REMOLD_ECHO_HISTORY_SAMPLES - REMOLD_ECHO_TEMPLATE_SAMPLES;

    /* First determine the direct/reference arrival. Subtracting this delay from
     * later echoes removes fixed speaker/trigger/electronics latency and makes
     * range depend on acoustic round-trip delay rather than host timing.
     */
    unsigned direct_delay = 0;
    float direct_strength = -1.0f;
    const unsigned direct_search_end = REMOLD_SCAN_FRAME_SAMPLES < scan_limit ?
                                       REMOLD_SCAN_FRAME_SAMPLES : scan_limit;
    for (unsigned d = 0; d < direct_search_end; ++d) {
        const float s = multi_channel_match(history, d, templ);
        if (s > direct_strength) { direct_strength = s; direct_delay = d; }
    }

    const float samples_per_meter = 2.0f * (float)engine->config.sample_rate_hz /
                                    engine->config.sound_speed_mps;
    unsigned min_delta = (unsigned)ceilf(engine->config.echo_min_range_m * samples_per_meter);
    unsigned max_delta = (unsigned)floorf(engine->config.echo_max_range_m * samples_per_meter);
    if (min_delta < REMOLD_ECHO_TEMPLATE_SAMPLES / 4u)
        min_delta = REMOLD_ECHO_TEMPLATE_SAMPLES / 4u;
    if (direct_delay + max_delta >= scan_limit)
        max_delta = scan_limit > direct_delay ? scan_limit - direct_delay - 1u : 0u;
    if (max_delta <= min_delta) return;

    EchoCandidate candidates[REMOLD_SCAN_MAX_REFLECTORS];
    unsigned candidate_count = 0;
    float prev = multi_channel_match(history, direct_delay + min_delta, templ);
    for (unsigned delta = min_delta + 1u; delta < max_delta; ++delta) {
        const unsigned d = direct_delay + delta;
        const float cur = multi_channel_match(history, d, templ);
        const float next = multi_channel_match(history, d + 1u, templ);
        if (cur >= engine->config.echo_threshold && cur >= prev && cur >= next) {
            int separated = 1;
            for (unsigned i = 0; i < candidate_count; ++i) {
                const unsigned a = candidates[i].delay;
                const unsigned diff = a > d ? a - d : d - a;
                if (diff < REMOLD_ECHO_TEMPLATE_SAMPLES / 3u) {
                    separated = 0;
                    if (cur > candidates[i].strength) {
                        candidates[i].delay = d;
                        candidates[i].strength = cur;
                    }
                    break;
                }
            }
            if (separated) insert_candidate(candidates, &candidate_count, d, cur);
        }
        prev = cur;
    }

    /* Strongest first. */
    for (unsigned i = 0; i < candidate_count; ++i) {
        for (unsigned j = i + 1u; j < candidate_count; ++j) {
            if (candidates[j].strength > candidates[i].strength) {
                EchoCandidate t = candidates[i];
                candidates[i] = candidates[j];
                candidates[j] = t;
            }
        }
    }

    for (unsigned c = 0; c < candidate_count; ++c) {
        const unsigned d = candidates[c].delay;
        int32_t frame[REMOLD_SCAN_CHANNELS][REMOLD_SCAN_FRAME_SAMPLES];
        memset(frame, 0, sizeof(frame));
        for (unsigned ch = 0; ch < REMOLD_SCAN_CHANNELS; ++ch) {
            for (unsigned n = 0; n < REMOLD_SCAN_FRAME_SAMPLES; ++n) {
                const unsigned src = d + n;
                if (src < REMOLD_ECHO_HISTORY_SAMPLES) frame[ch][n] = history[ch][src];
            }
        }
        RemoldScanFrame doa;
        remold_scan_process(engine, frame, &doa);
        RemoldReflector* r = &output->reflectors[output->reflector_count++];
        r->azimuth_deg = doa.peak_azimuth_deg;
        r->range_m = engine->config.sound_speed_mps * (float)(d - direct_delay) /
                     (2.0f * (float)engine->config.sample_rate_hz);
        r->strength = candidates[c].strength;
        r->confidence = candidates[c].strength * (0.35f + 0.65f * doa.confidence);
    }
}
