#include "../include/converter.h"

#include <stdlib.h>

struct Converter
{
    ma_data_converter converter;
    ConverterConfig config;
    ma_bool32 initialized;
};

ConverterConfig converter_config_default(
    int inputSampleRate,
    int outputSampleRate,
    int channels,
    ma_format format)
{
    ConverterConfig config;

    config.inputSampleRate = inputSampleRate;
    config.outputSampleRate = outputSampleRate;
    config.channels = channels;
    config.format = format;

    return config;
}

Converter* converter_create(void)
{
    return (Converter*)calloc(1, sizeof(Converter));
}

int converter_init(
    Converter* converter,
    const ConverterConfig* config)
{
    if (converter == NULL || config == NULL)
    {
        return 0;
    }

    converter->config = *config;

    ma_data_converter_config converterConfig =
        ma_data_converter_config_init(
            config->format,
            config->format,
            (ma_uint32)config->channels,
            (ma_uint32)config->channels,
            (ma_uint32)config->inputSampleRate,
            (ma_uint32)config->outputSampleRate);

    if (ma_data_converter_init(
            &converterConfig,
            NULL,
            &converter->converter) != MA_SUCCESS)
    {
        return 0;
    }

    converter->initialized = MA_TRUE;

    return 1;
}

int converter_process(
    Converter* converter,
    const void* input,
    int inputFrames,
    void* output,
    int outputCapacityFrames)
{
    if (converter == NULL ||
        converter->initialized == MA_FALSE ||
        input == NULL ||
        output == NULL)
    {
        return 0;
    }

    ma_uint64 inFrames = (ma_uint64)inputFrames;
    ma_uint64 outFrames = (ma_uint64)outputCapacityFrames;

    if (ma_data_converter_process_pcm_frames(
            &converter->converter,
            input,
            &inFrames,
            output,
            &outFrames) != MA_SUCCESS)
    {
        return 0;
    }

    return (int)outFrames;
}

void converter_destroy(
    Converter* converter)
{
    if (converter == NULL)
    {
        return;
    }

    if (converter->initialized)
    {
        ma_data_converter_uninit(
            &converter->converter,
            NULL);
    }

    free(converter);
}