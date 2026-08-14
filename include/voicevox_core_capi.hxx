// A trimmed mirror of VOICEVOX CORE's public C API (voicevox_core.h from the
// VOICEVOX/voicevox_core project, MIT licensed), covering only the ~10
// declarations src/voicevox_tts.cxx needs for one-shot text-to-speech: load
// the ONNX Runtime, construct an OpenJtalkRc + Synthesizer, load a .vvm voice
// model, and call the synthesizer's own `tts()` convenience entry point.
//
// This header exists so the engine can be *built* without VOICEVOX CORE
// present at all (no assets/voicevox/ downloaded, no configure-time
// find_library): src/voicevox_tts.cxx dlopen()s libvoicevox_core.so and
// dlsym()s each function against these prototypes at run time, exactly the
// way SDL_mixer's own MIDI patch set is an optional run-time asset rather
// than a build dependency (see src/sdl_audio.cxx's init_midi_config). The
// real, full header ships inside the downloaded archive at
// assets/voicevox/core/include/voicevox_core.h for reference; these
// declarations are trimmed to (and must stay binary-compatible with) VOICEVOX
// CORE 0.17.x's C API, which is what scripts/download-voicevox-zundamon.bash
// pins (0.16.x's `voicevox_synthesizer_load_voice_model` took two arguments,
// not three, and could not read the newer `vvm_format_version=2` files
// voicevox_vvm now ships -- see that script's version-pinning note).
//
// Struct layouts below match voicevox_core.h field-for-field: these are
// passed by value across the dlopen boundary, so the layout must be exact.

#ifndef VOICEVOX_CORE_CAPI_HXX
#define VOICEVOX_CORE_CAPI_HXX

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int32_t VoicevoxResultCode;
enum {
  VOICEVOX_RESULT_OK = 0,
};

typedef int32_t VoicevoxAccelerationMode;
enum {
  VOICEVOX_ACCELERATION_MODE_AUTO = 0,
  VOICEVOX_ACCELERATION_MODE_CPU = 1,
};

typedef struct OpenJtalkRc OpenJtalkRc;
typedef struct VoicevoxOnnxruntime VoicevoxOnnxruntime;
typedef struct VoicevoxSynthesizer VoicevoxSynthesizer;
typedef struct VoicevoxVoiceModelFile VoicevoxVoiceModelFile;

typedef uint32_t VoicevoxStyleId;

typedef struct VoicevoxLoadOnnxruntimeOptions {
  const char* filename;
} VoicevoxLoadOnnxruntimeOptions;

typedef struct VoicevoxInitializeOptions {
  VoicevoxAccelerationMode acceleration_mode;
  uint16_t cpu_num_threads;
} VoicevoxInitializeOptions;

typedef int32_t VoicevoxOnExistingVoiceModelId;
enum {
  VOICEVOX_ON_EXISTING_VOICE_MODEL_ID_ERROR = 0,
};

typedef struct VoicevoxLoadVoiceModelOptions {
  VoicevoxOnExistingVoiceModelId on_existing;
} VoicevoxLoadVoiceModelOptions;

typedef struct VoicevoxTtsOptions {
  bool enable_interrogative_upspeak;
} VoicevoxTtsOptions;

// -- function pointer types, one per dlsym()'d entry point ------------------
// (voicevox_core.h declares these as plain functions; src/voicevox_tts.cxx
// dlsym()s each symbol name into a pointer of the matching type below.)

typedef struct VoicevoxLoadOnnxruntimeOptions (
    *VoicevoxMakeDefaultLoadOnnxruntimeOptionsFn)(void);
typedef VoicevoxResultCode (*VoicevoxOnnxruntimeLoadOnceFn)(
    struct VoicevoxLoadOnnxruntimeOptions options,
    const struct VoicevoxOnnxruntime** out_onnxruntime);

typedef VoicevoxResultCode (*VoicevoxOpenJtalkRcNewFn)(
    const char* open_jtalk_dic_dir,
    struct OpenJtalkRc** out_open_jtalk);
typedef void (*VoicevoxOpenJtalkRcDeleteFn)(struct OpenJtalkRc* open_jtalk);

typedef struct VoicevoxInitializeOptions (
    *VoicevoxMakeDefaultInitializeOptionsFn)(void);
typedef VoicevoxResultCode (*VoicevoxSynthesizerNewFn)(
    const struct VoicevoxOnnxruntime* onnxruntime,
    const struct OpenJtalkRc* open_jtalk,
    struct VoicevoxInitializeOptions options,
    struct VoicevoxSynthesizer** out_synthesizer);
typedef void (*VoicevoxSynthesizerDeleteFn)(
    struct VoicevoxSynthesizer* synthesizer);

typedef VoicevoxResultCode (*VoicevoxVoiceModelFileOpenFn)(
    const char* path,
    struct VoicevoxVoiceModelFile** out_model);
typedef void (*VoicevoxVoiceModelFileDeleteFn)(
    struct VoicevoxVoiceModelFile* model);
typedef struct VoicevoxLoadVoiceModelOptions (
    *VoicevoxMakeDefaultLoadVoiceModelOptionsFn)(void);
typedef VoicevoxResultCode (*VoicevoxSynthesizerLoadVoiceModelFn)(
    const struct VoicevoxSynthesizer* synthesizer,
    const struct VoicevoxVoiceModelFile* model,
    struct VoicevoxLoadVoiceModelOptions options);

typedef struct VoicevoxTtsOptions (*VoicevoxMakeDefaultTtsOptionsFn)(void);
typedef VoicevoxResultCode (*VoicevoxSynthesizerTtsFn)(
    const struct VoicevoxSynthesizer* synthesizer,
    const char* text,
    VoicevoxStyleId style_id,
    struct VoicevoxTtsOptions options,
    uintptr_t* output_wav_length,
    uint8_t** output_wav);
typedef void (*VoicevoxWavFreeFn)(uint8_t* wav);

typedef const char* (*VoicevoxErrorResultToMessageFn)(
    VoicevoxResultCode result_code);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // VOICEVOX_CORE_CAPI_HXX
