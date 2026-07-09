#ifndef CONVERTER_H
#define CONVERTER_H

#include <stdint.h>

#if __has_include("../external/miniaudio/include/miniaudio.h")
#include "../external/miniaudio/include/miniaudio.h"
#elif __has_include("miniaudio.h")
#include "miniaudio.h"
#else
#error "miniaudio.h not found"
#endif

#include "export.h"

#ifdef __cplusplus
extern "C" {
#endif


typedef struct Converter Converter;


typedef struct ConverterConfig {

    int       inputSampleRate;
    int       outputSampleRate;
    int       channels;
    ma_format format;

} ConverterConfig;



EXPORT ConverterConfig converter_config_default(
    int inputSampleRate,
    int outputSampleRate,
    int channels,
    ma_format format
);



EXPORT Converter* converter_create(void);


EXPORT void converter_destroy(
    Converter* converter
);



EXPORT int converter_init(
    Converter* converter,
    const ConverterConfig* config
);



EXPORT int converter_process(
    Converter* converter,
    const void* input,
    int inputFrames,
    void* output,
    int outputCapacityFrames
);



#ifdef __cplusplus
}
#endif

#endif /* CONVERTER_H */