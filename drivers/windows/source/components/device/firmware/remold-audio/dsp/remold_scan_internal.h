#pragma once
#include "../include/remold_acoustic_scan.h"
#include "remold_fft.h"

#define REMOLD_PAIR_COUNT 6u

typedef struct RemoldPair {
    uint8_t a;
    uint8_t b;
} RemoldPair;

struct RemoldScanEngine {
    RemoldScanConfig config;
    uint64_t frame_number;
    uint64_t echo_number;
    float occupancy[REMOLD_SCAN_AZIMUTH_BINS];
    RemoldComplex spectra[REMOLD_SCAN_CHANNELS][REMOLD_SCAN_FFT_SIZE];
    float pair_corr[REMOLD_PAIR_COUNT][REMOLD_SCAN_FFT_SIZE];
};
