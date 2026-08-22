#include "remold_fft.h"
#include <math.h>

#ifndef REMOLD_PI
#define REMOLD_PI 3.14159265358979323846f
#endif

static void swap_complex(RemoldComplex* a, RemoldComplex* b) {
    RemoldComplex t = *a;
    *a = *b;
    *b = t;
}

void remold_fft(RemoldComplex* data, size_t n, int inverse) {
    size_t j = 0;
    for (size_t i = 1; i < n; ++i) {
        size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) swap_complex(&data[i], &data[j]);
    }

    for (size_t len = 2; len <= n; len <<= 1) {
        const float angle = (inverse ? 2.0f : -2.0f) * REMOLD_PI / (float)len;
        const RemoldComplex wlen = { cosf(angle), sinf(angle) };
        for (size_t i = 0; i < n; i += len) {
            RemoldComplex w = {1.0f, 0.0f};
            for (size_t k = 0; k < len / 2; ++k) {
                RemoldComplex u = data[i + k];
                RemoldComplex q = data[i + k + len / 2];
                RemoldComplex v = {
                    q.re * w.re - q.im * w.im,
                    q.re * w.im + q.im * w.re
                };
                data[i + k].re = u.re + v.re;
                data[i + k].im = u.im + v.im;
                data[i + k + len / 2].re = u.re - v.re;
                data[i + k + len / 2].im = u.im - v.im;
                RemoldComplex nw = {
                    w.re * wlen.re - w.im * wlen.im,
                    w.re * wlen.im + w.im * wlen.re
                };
                w = nw;
            }
        }
    }

    if (inverse) {
        const float inv = 1.0f / (float)n;
        for (size_t i = 0; i < n; ++i) {
            data[i].re *= inv;
            data[i].im *= inv;
        }
    }
}
