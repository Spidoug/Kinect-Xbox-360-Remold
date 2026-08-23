#include "../include/remold_acoustic_scan.h"
#include "../dsp/remold_scan_internal.h"
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static uint32_t rng=0x12345678u;
static float noise_sample(void) {
    rng = rng * 1664525u + 1013904223u;
    return ((float)((rng >> 8) & 0xFFFFu) / 32768.0f) - 1.0f;
}

static float sample_linear(const float* x, int n, float pos) {
    int i=(int)floorf(pos);
    float f=pos-(float)i;
    if(i<0 || i+1>=n) return 0.0f;
    return x[i]*(1.0f-f)+x[i+1]*f;
}

static int check_angle(RemoldScanEngine* engine, const RemoldScanConfig* cfg, float expected) {
    enum { PAD=64, N=REMOLD_SCAN_FRAME_SAMPLES+2*PAD };
    float src[N];
    for(int i=0;i<N;i++)
        src[i]=0.65f*noise_sample()+0.25f*sinf(2.0f*3.14159265f*1300.0f*(float)i/16000.0f);

    const float s=sinf(expected*3.14159265f/180.0f);
    int32_t frame[REMOLD_SCAN_CHANNELS][REMOLD_SCAN_FRAME_SAMPLES];
    memset(frame,0,sizeof(frame));
    for(unsigned ch=0;ch<REMOLD_SCAN_CHANNELS;ch++) {
        const float advance=cfg->geometry.x_m[ch]*s*(float)cfg->sample_rate_hz/cfg->sound_speed_mps;
        for(unsigned n=0;n<REMOLD_SCAN_FRAME_SAMPLES;n++) {
            float v=sample_linear(src,N,(float)(PAD+n)+advance);
            if (v > 1.0f) v = 1.0f;
            if (v < -1.0f) v = -1.0f;
            frame[ch][n]=(int32_t)(v*1000000000.0f);
        }
    }
    RemoldScanFrame out;
    remold_scan_process(engine,frame,&out);
    printf("angle expected=%6.2f estimated=%6.2f confidence=%.3f rms=%.4f\n",
           expected,out.peak_azimuth_deg,out.confidence,out.rms);
    if(fabsf(out.peak_azimuth_deg-expected)>8.0f) return 2;
    if(out.peak_score<0.95f) return 3;
    return 0;
}

static int check_echo(RemoldScanEngine* engine, const RemoldScanConfig* cfg) {
    float chirp[REMOLD_ECHO_TEMPLATE_SAMPLES];
    remold_echo_template(chirp);
    float energy=0.0f;
    for(unsigned i=0;i<REMOLD_ECHO_TEMPLATE_SAMPLES;i++) energy+=chirp[i]*chirp[i];
    if(energy<5.0f) return 10;

    int32_t hist[REMOLD_SCAN_CHANNELS][REMOLD_ECHO_HISTORY_SAMPLES];
    memset(hist,0,sizeof(hist));
    const float angle=24.0f;
    const float s=sinf(angle*3.14159265f/180.0f);
    const int direct=24;
    const int echo_delay=232;
    for(unsigned ch=0;ch<REMOLD_SCAN_CHANNELS;ch++) {
        const float advance=cfg->geometry.x_m[ch]*s*(float)cfg->sample_rate_hz/cfg->sound_speed_mps;
        for(unsigned n=0;n<REMOLD_ECHO_HISTORY_SAMPLES;n++) {
            float v=0.0f;
            float td=(float)n-(float)direct+advance;
            if(td>=0.0f && td<(float)(REMOLD_ECHO_TEMPLATE_SAMPLES-1u))
                v += 0.75f*sample_linear(chirp,REMOLD_ECHO_TEMPLATE_SAMPLES,td);
            float te=(float)n-(float)echo_delay+advance;
            if(te>=0.0f && te<(float)(REMOLD_ECHO_TEMPLATE_SAMPLES-1u))
                v += 0.43f*sample_linear(chirp,REMOLD_ECHO_TEMPLATE_SAMPLES,te);
            v += 0.004f*noise_sample();
            hist[ch][n]=(int32_t)(v*1000000000.0f);
        }
    }

    RemoldEchoFrame out;
    remold_echo_process(engine,hist,&out);
    const float expected_range=cfg->sound_speed_mps*(float)(echo_delay-direct)/(2.0f*(float)cfg->sample_rate_hz);
    printf("echo reflectors=%u expected_range=%.3f m\n",out.reflector_count,expected_range);
    for(unsigned i=0;i<out.reflector_count;i++)
        printf("  #%u az=%.2f range=%.3f strength=%.3f confidence=%.3f\n",
               i,out.reflectors[i].azimuth_deg,out.reflectors[i].range_m,
               out.reflectors[i].strength,out.reflectors[i].confidence);
    if(out.reflector_count==0) return 11;
    float best_error=999.0f;
    for(unsigned i=0;i<out.reflector_count;i++) {
        float e=fabsf(out.reflectors[i].range_m-expected_range);
        if(e<best_error) best_error=e;
    }
    if(best_error>0.08f) return 12;
    return 0;
}

int main(void) {
    RemoldScanConfig cfg;
    remold_scan_default_config(&cfg);
    RemoldScanEngine engine;
    remold_scan_init(&engine,&cfg);

    const float angles[]={-55.0f,-30.0f,0.0f,32.0f,58.0f};
    for(unsigned i=0;i<sizeof(angles)/sizeof(angles[0]);i++) {
        int rc=check_angle(&engine,&cfg,angles[i]);
        if(rc) return rc;
    }
    int rc=check_echo(&engine,&cfg);
    if(rc) return rc;
    puts("ACOUSTIC DSP SELF-TEST: PASS");
    return 0;
}
