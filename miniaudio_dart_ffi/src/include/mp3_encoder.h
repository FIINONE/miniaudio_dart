#ifndef MP3_ENCODER_H
#define MP3_ENCODER_H

#include <stdint.h>

#include "export.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Mp3Encoder Mp3Encoder;

EXPORT Mp3Encoder* mp3_encoder_create(void);
EXPORT void        mp3_encoder_destroy(Mp3Encoder* enc);

/* channels: 1 (mono) or 2 (stereo). bitrateKbps: e.g. 16-32 for voice, 64-128 for music. */
EXPORT int mp3_encoder_init(Mp3Encoder* enc, int sampleRate, int channels, int bitrateKbps);

/* pcm: interleaved 16-bit PCM samples. frameCount: number of frames (not samples).
   Returns bytes written to outBuf, 0 if LAME buffered the input internally
   without producing output yet, or -1 on error. */
EXPORT int mp3_encoder_encode_s16(Mp3Encoder* enc,
                                  const int16_t* pcm,
                                  int frameCount,
                                  uint8_t* outBuf,
                                  int outCap);

/* Call once after the last mp3_encoder_encode_s16 call to flush any
   buffered MP3 frames. Returns bytes written, or -1 on error. */
EXPORT int mp3_encoder_flush(Mp3Encoder* enc, uint8_t* outBuf, int outCap);

#ifdef __cplusplus
}
#endif
#endif /* MP3_ENCODER_H */
