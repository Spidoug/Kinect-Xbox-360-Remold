#pragma once
#include <stddef.h>

typedef struct RemoldComplex {
    float re;
    float im;
} RemoldComplex;

void remold_fft(RemoldComplex* data, size_t n, int inverse);
