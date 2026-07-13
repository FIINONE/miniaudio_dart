#include "../include/mp3_encoder.h"

#include <stdarg.h>
#include <stdlib.h>

#ifdef HAVE_MP3
#if MP3_HEADER_FLAT
#include <lame.h>
#else
#include <lame/lame.h>
#endif

/* LAME prints internal diagnostics (bit-allocation accounting, "amplification
   over limits" warnings, etc.) straight to stderr via these callbacks unless
   overridden. They're harmless encoder chatter, not errors - silence them. */
static void mp3_encoder_silent_report(const char* format, va_list ap) {
    (void)format;
    (void)ap;
}
#endif

struct Mp3Encoder {
#ifdef HAVE_MP3
    lame_global_flags* gfp;
#else
    int unused;
#endif
};

Mp3Encoder* mp3_encoder_create(void) {
    return (Mp3Encoder*)calloc(1, sizeof(Mp3Encoder));
}

void mp3_encoder_destroy(Mp3Encoder* enc) {
    if (!enc) return;
#ifdef HAVE_MP3
    if (enc->gfp) lame_close(enc->gfp);
#endif
    free(enc);
}

int mp3_encoder_init(Mp3Encoder* enc, int sampleRate, int channels, int bitrateKbps) {
#ifdef HAVE_MP3
    if (!enc || sampleRate <= 0 || channels <= 0 || channels > 2 || bitrateKbps <= 0) return 0;

    enc->gfp = lame_init();
    if (!enc->gfp) return 0;

    lame_set_errorf(enc->gfp, mp3_encoder_silent_report);
    lame_set_debugf(enc->gfp, mp3_encoder_silent_report);
    lame_set_msgf(enc->gfp, mp3_encoder_silent_report);

    lame_set_in_samplerate(enc->gfp, sampleRate);
    lame_set_num_channels(enc->gfp, channels);
    lame_set_brate(enc->gfp, bitrateKbps);
    lame_set_mode(enc->gfp, channels == 1 ? MONO : STEREO);
    lame_set_quality(enc->gfp, 5); /* 0 = best/slowest, 9 = worst/fastest */

    if (lame_init_params(enc->gfp) < 0) {
        lame_close(enc->gfp);
        enc->gfp = NULL;
        return 0;
    }
    return 1;
#else
    (void)enc; (void)sampleRate; (void)channels; (void)bitrateKbps;
    return 0;
#endif
}

int mp3_encoder_encode_s16(Mp3Encoder* enc,
                           const int16_t* pcm,
                           int frameCount,
                           uint8_t* outBuf,
                           int outCap)
{
#ifdef HAVE_MP3
    if (!enc || !enc->gfp || !pcm || frameCount <= 0 || !outBuf || outCap <= 0) return -1;

    if (lame_get_num_channels(enc->gfp) == 1) {
        return lame_encode_buffer(enc->gfp, pcm, pcm, frameCount, outBuf, outCap);
    }
    return lame_encode_buffer_interleaved(enc->gfp, (short*)pcm, frameCount, outBuf, outCap);
#else
    (void)enc; (void)pcm; (void)frameCount; (void)outBuf; (void)outCap;
    return -1;
#endif
}

int mp3_encoder_flush(Mp3Encoder* enc, uint8_t* outBuf, int outCap) {
#ifdef HAVE_MP3
    if (!enc || !enc->gfp || !outBuf || outCap <= 0) return -1;
    return lame_encode_flush(enc->gfp, outBuf, outCap);
#else
    (void)enc; (void)outBuf; (void)outCap;
    return -1;
#endif
}
