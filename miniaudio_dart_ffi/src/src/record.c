#include "../include/record.h"
#include <stdlib.h>
#include <string.h>

typedef struct {
    char        name[256];
    ma_device_id id;
    ma_bool32   isDefault;
} CaptureDeviceInfo;

/* Internal structure */
struct Recorder {
    ma_device        device;
    ma_device_config deviceConfig;
    int              sampleRate;
    int              channels;
    ma_format        format;
    ma_uint32        frameSizeBytes;
    int              isRecording;
    float            gain;

    /* Ring buffer - stores PCM frames */
    ma_pcm_rb        rb;

    /* Device enumeration context & cache */
    ma_context            context;
    int                   context_initialized;
    CaptureDeviceInfo*    captureInfos;
    ma_uint32             captureCount;
    ma_uint32             captureGeneration;
};

static void data_callback(ma_device* dev, void* pOutput, const void* pInput, ma_uint32 frameCount) {
    (void)pOutput;
    Recorder* r = (Recorder*)dev->pUserData;
    if(!r || !pInput || frameCount==0) return;

    const float g = r->gain;
    const ma_uint32 bpf = r->frameSizeBytes;
    const ma_uint8* srcBytes = (const ma_uint8*)pInput;

    ma_uint32 remaining = frameCount;
    while(remaining > 0) {
        ma_uint32 req = remaining;
        void* pWrite = NULL;
        if(ma_pcm_rb_acquire_write(&r->rb, &req, &pWrite) != MA_SUCCESS || req==0) break;

        if (g != 1.0f) {
            if (r->format == ma_format_f32) {
                const float* s = (const float*)srcBytes;
                float* d = (float*)pWrite;

                ma_uint32 samples = req * (ma_uint32)r->channels;

                for (ma_uint32 i = 0; i < samples; i++) {
                    d[i] = s[i] * g;
                }
            } else if (r->format == ma_format_s16) {
                const int16_t* s = (const int16_t*)srcBytes;
                int16_t* d = (int16_t*)pWrite;

                ma_uint32 samples = req * (ma_uint32)r->channels;

                for (ma_uint32 i = 0; i < samples; i++) {
                    int32_t value = (int32_t)(s[i] * g);

                    if (value > INT16_MAX) value = INT16_MAX;
                    if (value < INT16_MIN) value = INT16_MIN;

                    d[i] = (int16_t)value;
                }
            } else {
                memcpy(pWrite, srcBytes, (size_t)req * bpf);
            }
        } else {
            memcpy(pWrite, srcBytes, (size_t)req * bpf);
        }

        ma_pcm_rb_commit_write(&r->rb, req);
        srcBytes   += (size_t)req * bpf;
        remaining  -= req;
    }
}

RecorderConfig recorder_config_default(int sampleRate, int channels, ma_format format) {
    RecorderConfig cfg;
    cfg.sampleRate            = sampleRate;
    cfg.channels              = channels;
    cfg.format                = format;
    cfg.bufferDurationSeconds = 5;
    cfg.autoStart             = 0;
    return cfg;
}

Recorder* recorder_create(void) {
    return (Recorder*)calloc(1, sizeof(Recorder));
}

/* Initialize context lazily */
static int recorder_ensure_context(Recorder* r) {
    if (!r) return 0;
    if (r->context_initialized) return 1;

    ma_context_config cfg = ma_context_config_init();
    if (ma_context_init(NULL, 0, &cfg, &r->context) != MA_SUCCESS) {
        return 0;
    }
    r->context_initialized = 1;
    return 1;
}

void recorder_free_capture_cache(Recorder* r) {
    if (!r) return;
    if (r->captureInfos) {
        free(r->captureInfos);
        r->captureInfos = NULL;
    }
    r->captureCount = 0;
}

int recorder_refresh_capture_devices(Recorder* r) {
    if (!r) return 0;
    if (!recorder_ensure_context(r)) return 0;

    ma_device_info* pPlayback = NULL;
    ma_uint32 playbackCount = 0;
    ma_device_info* pCapture = NULL;
    ma_uint32 captureCount = 0;

    if (ma_context_get_devices(&r->context, &pPlayback, &playbackCount,
                               &pCapture, &captureCount) != MA_SUCCESS) {
        return 0;
    }

    recorder_free_capture_cache(r);
    if (captureCount == 0) {
        r->captureGeneration++;
        return 1;
    }

    r->captureInfos = (CaptureDeviceInfo*)malloc(sizeof(CaptureDeviceInfo) * captureCount);
    if (!r->captureInfos) return 0;

    for (ma_uint32 i = 0; i < captureCount; i++) {
        CaptureDeviceInfo* dst = &r->captureInfos[i];
        ma_device_info* src = &pCapture[i];
        memset(dst, 0, sizeof(*dst));
        strncpy(dst->name, src->name, 255);
        dst->name[255] = '\0';
        dst->id = src->id;
        dst->isDefault = src->isDefault;
    }
    r->captureCount = captureCount;
    r->captureGeneration++;
    return 1;
}

ma_uint32 recorder_get_capture_device_count(Recorder* r) {
    return r ? r->captureCount : 0;
}

int recorder_get_capture_device_name(Recorder* r, ma_uint32 index,
                                     char* outName, ma_uint32 capName,
                                     ma_bool32* pIsDefault) {
    if (!r || index >= r->captureCount || !outName || capName == 0) return 0;

    CaptureDeviceInfo* info = &r->captureInfos[index];
    strncpy(outName, info->name, capName - 1);
    outName[capName - 1] = '\0';
    if (pIsDefault) *pIsDefault = info->isDefault;
    return 1;
}

ma_uint32 recorder_get_capture_device_generation(Recorder* r) {
    return r ? r->captureGeneration : 0;
}

int recorder_select_capture_device_by_index(Recorder* r, ma_uint32 index) {
    if (!r || index >= r->captureCount) return 0;

    /* Preserve state */
    int wasRecording = r->isRecording;
    if (wasRecording) {
        ma_device_stop(&r->device);
        r->isRecording = 0;
    }
    ma_device_uninit(&r->device);

    /* Rebuild device config with chosen ID */
    r->deviceConfig = ma_device_config_init(ma_device_type_capture);
    r->deviceConfig.capture.format   = r->format;
    r->deviceConfig.capture.channels = (ma_uint32)r->channels;
    r->deviceConfig.sampleRate       = (ma_uint32)r->sampleRate;
    r->deviceConfig.dataCallback     = data_callback;
    r->deviceConfig.pUserData        = r;
    r->deviceConfig.capture.pDeviceID = &r->captureInfos[index].id;

    if (ma_device_init(&r->context, &r->deviceConfig, &r->device) != MA_SUCCESS) {
        /* Attempt fallback to default (NULL context / default device) */
        r->deviceConfig.capture.pDeviceID = NULL;
        if (ma_device_init(NULL, &r->deviceConfig, &r->device) != MA_SUCCESS) {
            return 0;
        }
    }

    if (wasRecording) {
        if (ma_device_start(&r->device) == MA_SUCCESS) {
            r->isRecording = 1;
        }
    }

    r->captureGeneration++; /* device change event */
    return 1;
}

void recorder_destroy(Recorder* r) {
    if(!r) return;
    if(r->isRecording) ma_device_stop(&r->device);
    ma_device_uninit(&r->device);
    if(r->context_initialized) {
        ma_context_uninit(&r->context);
        r->context_initialized = 0;
    }
    recorder_free_capture_cache(r);
    ma_pcm_rb_uninit(&r->rb);
    free(r);
}

int recorder_init(Recorder* r, const RecorderConfig* cfg) {
    if(!r || !cfg) return 0;
    if(cfg->channels <= 0 || cfg->sampleRate <= 0) return 0;

    r->sampleRate     = cfg->sampleRate;
    r->channels       = cfg->channels;
    r->format         = cfg->format;
    r->frameSizeBytes = (ma_uint32)(ma_get_bytes_per_sample(r->format) * r->channels);
    r->isRecording    = 0;
    r->gain           = 1.0f;

    ma_uint64 capacityFrames = (ma_uint64)cfg->sampleRate * (ma_uint64)cfg->bufferDurationSeconds;
    if(capacityFrames < 1024) capacityFrames = 1024;
    if(capacityFrames > 0x7FFFFFFFULL) capacityFrames = 0x7FFFFFFF;

    if(ma_pcm_rb_init(r->format, (ma_uint32)r->channels, (ma_uint32)capacityFrames, NULL, NULL, &r->rb) != MA_SUCCESS) {
        return 0;
    }

    /* Initialize device */
    r->deviceConfig = ma_device_config_init(ma_device_type_capture);
    r->deviceConfig.capture.format   = r->format;
    r->deviceConfig.capture.channels = (ma_uint32)r->channels;
    r->deviceConfig.sampleRate       = (ma_uint32)r->sampleRate;
    r->deviceConfig.dataCallback     = data_callback;
    r->deviceConfig.pUserData        = r;

    if(ma_device_init(NULL, &r->deviceConfig, &r->device) != MA_SUCCESS) {
        ma_pcm_rb_uninit(&r->rb);
        return 0;
    }

    if(cfg->autoStart) recorder_start(r);
    return 1;
}

int recorder_start(Recorder* r) {
    if(!r) return 0;
    if(r->isRecording) return 1;
    if(ma_device_start(&r->device) != MA_SUCCESS) return 0;
    r->isRecording = 1;
    return 1;
}

int recorder_stop(Recorder* r) {
    if(!r) return 0;
    if(!r->isRecording) return 1;
    ma_device_stop(&r->device);
    r->isRecording = 0;
    return 1;
}

int recorder_is_recording(const Recorder* r) {
    return (r && r->isRecording) ? 1 : 0;
}

int recorder_get_available_frames(Recorder* r) {
    if(!r) return 0;
    return (int)ma_pcm_rb_available_read(&r->rb);
}

int recorder_acquire_read_region(Recorder* r, void** outPtr, int* outFrames) {
    if(!r || !outPtr || !outFrames) return 0;
    ma_uint32 avail = ma_pcm_rb_available_read(&r->rb);
    if(avail == 0) {
        *outPtr = NULL;
        *outFrames = 0;
        return 1;
    }
    void* pRead = NULL;
    if(ma_pcm_rb_acquire_read(&r->rb, &avail, &pRead) != MA_SUCCESS) return 0;
    *outPtr    = pRead;
    *outFrames = (int)avail;
    return 1;
}

int recorder_commit_read_frames(Recorder* r, int frames) {
    if(!r || frames < 0) return 0;
    if(frames == 0) return 1;
    ma_pcm_rb_commit_read(&r->rb, (ma_uint32)frames);
    return 1;
}

void recorder_set_capture_gain(Recorder* r, float gain) {
    if(!r) return;
    r->gain = gain;
}

float recorder_get_capture_gain(Recorder* r) {
    return r ? r->gain : 1.0f;
}
