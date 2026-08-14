// VOICEVOX CORE backend for RGSS::Tts (Zundamon message-window narration),
// installed at startup by rgss_tts_init() when --zundamon_tts is passed (see
// src/main.cxx). Mirrors src/sdl_audio.cxx's split: the mruby-rgss gem must
// not depend on VOICEVOX CORE or SDL, so RGSS::Tts's native methods
// (mruby-rgss/src/tts.cxx) call through the plain function table in
// include/rgss_tts.hxx instead of calling either directly.
//
// VOICEVOX CORE itself is never a build dependency: the library, its ONNX
// Runtime, the Open JTalk dictionary and Zundamon's voice model are an
// optional run-time asset (scripts/download-voicevox-zundamon.bash installs
// them into assets/voicevox, git-ignored -- see assets/voicevox/README.md),
// dlopen()'d here the same way SDL_mixer's MIDI patch set is an optional
// run-time asset rather than a link-time one. With no assets/voicevox
// present -- the common case, since this is an opt-in accessibility feature
// -- every RGSS::Tts call is a graceful no-op: RGSS::Tts.available? reports
// false and nothing is logged beyond one INFO line explaining why.
//
// Licensing note: Zundamon's voice model requires crediting "VOICEVOX:
// ずんだもん" wherever audio generated with it is used (see
// assets/voicevox/models/TERMS.txt) -- this is a property of the downloaded
// model, not of this source file, which only calls a documented C API.

#include "rgss_tts.hxx"

#include "voicevox_core_capi.hxx"

// VOICEVOX CORE ships as a native shared library with no Emscripten/PSP/Wio
// port, so this backend only makes sense where dlopen() is both available and
// meaningful -- the desktop native build. Everywhere else rgss_tts_init()
// below leaves the backend uninstalled.
#if !defined(__EMSCRIPTEN__) && (defined(__linux__) || defined(__APPLE__))
#define RGSS_TTS_HAVE_DLOPEN 1
#include <dlfcn.h>
#endif

#include <SDL2/SDL.h>
#if defined(__has_include) && __has_include(<SDL2/SDL_mixer.h>)
#include <SDL2/SDL_mixer.h>
#else
#include <SDL_mixer.h>
#endif

#include <ng-log/logging.h>

#include <cstdio>
#include <string>

#if defined(RGSS_TTS_HAVE_DLOPEN)

namespace {

// Zundamon's "ノーマル" (normal) style, style id 3 in voicevox_vvm's `0.vvm`
// -- see assets/voicevox/models/TERMS.txt and the character/style table at
// https://github.com/VOICEVOX/voicevox_vvm/blob/main/README.md. This is the
// one style scripts/download-voicevox-zundamon.bash installs.
constexpr VoicevoxStyleId kZundamonNormalStyleId = 3;

void* g_core = nullptr;
bool g_init_attempted = false;
bool g_available = false;

VoicevoxMakeDefaultLoadOnnxruntimeOptionsFn
    p_make_default_load_onnxruntime_options = nullptr;
VoicevoxOnnxruntimeLoadOnceFn p_onnxruntime_load_once = nullptr;
VoicevoxOpenJtalkRcNewFn p_open_jtalk_rc_new = nullptr;
VoicevoxOpenJtalkRcDeleteFn p_open_jtalk_rc_delete = nullptr;
VoicevoxMakeDefaultInitializeOptionsFn p_make_default_initialize_options =
    nullptr;
VoicevoxSynthesizerNewFn p_synthesizer_new = nullptr;
VoicevoxSynthesizerDeleteFn p_synthesizer_delete = nullptr;
VoicevoxVoiceModelFileOpenFn p_voice_model_file_open = nullptr;
VoicevoxVoiceModelFileDeleteFn p_voice_model_file_delete = nullptr;
VoicevoxMakeDefaultLoadVoiceModelOptionsFn
    p_make_default_load_voice_model_options = nullptr;
VoicevoxSynthesizerLoadVoiceModelFn p_synthesizer_load_voice_model = nullptr;
VoicevoxMakeDefaultTtsOptionsFn p_make_default_tts_options = nullptr;
VoicevoxSynthesizerTtsFn p_synthesizer_tts = nullptr;
VoicevoxWavFreeFn p_wav_free = nullptr;
VoicevoxErrorResultToMessageFn p_error_result_to_message = nullptr;

const VoicevoxOnnxruntime* g_onnxruntime = nullptr;
OpenJtalkRc* g_open_jtalk = nullptr;
VoicevoxSynthesizer* g_synthesizer = nullptr;
VoicevoxVoiceModelFile* g_model = nullptr;

// The one outstanding synthesized clip. At most one utterance plays at a
// time -- a new message page's narration replaces whatever the previous page
// started, the same way starting a new BGM replaces the one already playing
// -- so there is never more than a single Mix_Chunk to track, freed the
// moment a new speak() replaces it or at shutdown.
int g_channel = -1;
Mix_Chunk* g_chunk = nullptr;

bool file_exists(const std::string& path) {
  FILE* f = std::fopen(path.c_str(), "rb");
  if (!f)
    return false;
  std::fclose(f);
  return true;
}

// Where assets/voicevox lives: next to the executable (an installed layout,
// or a build tree with the assets downloaded in place) first, then the
// source tree -- the same search order and reasoning as init_midi_config's
// TIMIDITY_CFG lookup in src/sdl_audio.cxx.
std::string resolve_voicevox_dir() {
  if (char* base = SDL_GetBasePath()) {
    std::string candidate = std::string(base) + "assets/voicevox";
    SDL_free(base);
    if (file_exists(candidate + "/core/lib/libvoicevox_core.so"))
      return candidate;
  }
#ifdef RGSS_VOICEVOX_SOURCE_DIR
  if (file_exists(std::string(RGSS_VOICEVOX_SOURCE_DIR) +
                  "/core/lib/libvoicevox_core.so"))
    return RGSS_VOICEVOX_SOURCE_DIR;
#endif
  return std::string();
}

template <typename Fn>
bool load_symbol(void* handle, const char* name, Fn& out) {
  out = reinterpret_cast<Fn>(dlsym(handle, name));
  if (!out)
    LOG(WARNING) << "Tts: missing symbol '" << name
                 << "' in libvoicevox_core.so";
  return out != nullptr;
}

bool check(VoicevoxResultCode code, const char* what) {
  if (code == VOICEVOX_RESULT_OK)
    return true;
  const char* msg = p_error_result_to_message ? p_error_result_to_message(code)
                                              : "(no detail)";
  LOG(WARNING) << "Tts: " << what << " failed (code " << code << "): " << msg;
  return false;
}

// Loads libvoicevox_core.so and stands up a Synthesizer with Zundamon's voice
// model loaded. Runs once: model loading costs real disk IO and an ONNX
// Runtime session, so rgss_tts_init() calls this eagerly at startup rather
// than paying that cost on the first message the game happens to show.
void ensure_init() {
  if (g_init_attempted)
    return;
  g_init_attempted = true;

  const std::string dir = resolve_voicevox_dir();
  if (dir.empty()) {
    LOG(INFO) << "Tts: no assets/voicevox found; --zundamon_tts stays "
                 "unavailable (run scripts/download-voicevox-zundamon.bash to "
                 "install it)";
    return;
  }

  const std::string core_so = dir + "/core/lib/libvoicevox_core.so";
  g_core = dlopen(core_so.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!g_core) {
    LOG(WARNING) << "Tts: dlopen('" << core_so << "') failed: " << dlerror();
    return;
  }

  bool ok = true;
  ok &= load_symbol(g_core, "voicevox_make_default_load_onnxruntime_options",
                    p_make_default_load_onnxruntime_options);
  ok &= load_symbol(g_core, "voicevox_onnxruntime_load_once",
                    p_onnxruntime_load_once);
  ok &= load_symbol(g_core, "voicevox_open_jtalk_rc_new", p_open_jtalk_rc_new);
  ok &= load_symbol(g_core, "voicevox_open_jtalk_rc_delete",
                    p_open_jtalk_rc_delete);
  ok &= load_symbol(g_core, "voicevox_make_default_initialize_options",
                    p_make_default_initialize_options);
  ok &= load_symbol(g_core, "voicevox_synthesizer_new", p_synthesizer_new);
  ok &=
      load_symbol(g_core, "voicevox_synthesizer_delete", p_synthesizer_delete);
  ok &= load_symbol(g_core, "voicevox_voice_model_file_open",
                    p_voice_model_file_open);
  ok &= load_symbol(g_core, "voicevox_voice_model_file_delete",
                    p_voice_model_file_delete);
  ok &= load_symbol(g_core, "voicevox_make_default_load_voice_model_options",
                    p_make_default_load_voice_model_options);
  ok &= load_symbol(g_core, "voicevox_synthesizer_load_voice_model",
                    p_synthesizer_load_voice_model);
  ok &= load_symbol(g_core, "voicevox_make_default_tts_options",
                    p_make_default_tts_options);
  ok &= load_symbol(g_core, "voicevox_synthesizer_tts", p_synthesizer_tts);
  ok &= load_symbol(g_core, "voicevox_wav_free", p_wav_free);
  // Best-effort only: used for a nicer log message, nothing depends on it.
  load_symbol(g_core, "voicevox_error_result_to_message",
              p_error_result_to_message);
  if (!ok) {
    dlclose(g_core);
    g_core = nullptr;
    return;
  }

  VoicevoxLoadOnnxruntimeOptions ort_opts =
      p_make_default_load_onnxruntime_options();
  const std::string ort_so =
      dir + "/onnxruntime/lib/libvoicevox_onnxruntime.so";
  ort_opts.filename = ort_so.c_str();
  if (!check(p_onnxruntime_load_once(ort_opts, &g_onnxruntime),
             "loading the ONNX Runtime"))
    return;

  const std::string dict_dir = dir + "/dict/open_jtalk_dic_utf_8-1.11";
  if (!check(p_open_jtalk_rc_new(dict_dir.c_str(), &g_open_jtalk),
             "loading the Open JTalk dictionary"))
    return;

  VoicevoxInitializeOptions init_opts = p_make_default_initialize_options();
  init_opts.acceleration_mode = VOICEVOX_ACCELERATION_MODE_CPU;
  if (!check(p_synthesizer_new(g_onnxruntime, g_open_jtalk, init_opts,
                               &g_synthesizer),
             "constructing the synthesizer"))
    return;

  const std::string model_path = dir + "/models/0.vvm";
  if (!check(p_voice_model_file_open(model_path.c_str(), &g_model),
             "opening the Zundamon voice model"))
    return;
  if (!check(p_synthesizer_load_voice_model(
                 g_synthesizer, g_model,
                 p_make_default_load_voice_model_options()),
             "loading the Zundamon voice model"))
    return;

  g_available = true;
  LOG(INFO) << "Tts: Zundamon voice model loaded from '" << dir << "'";
}

void free_chunk() {
  if (g_channel >= 0) {
    Mix_HaltChannel(g_channel);
    g_channel = -1;
  }
  if (g_chunk) {
    Mix_FreeChunk(g_chunk);
    g_chunk = nullptr;
  }
}

int available_fn(void) {
  return g_available ? 1 : 0;
}

void speak_fn(const char* utf8_text) {
  if (!g_available || !utf8_text || !*utf8_text)
    return;

  VoicevoxTtsOptions opts = p_make_default_tts_options();
  uintptr_t wav_len = 0;
  uint8_t* wav = nullptr;
  VoicevoxResultCode code = p_synthesizer_tts(
      g_synthesizer, utf8_text, kZundamonNormalStyleId, opts, &wav_len, &wav);
  if (!check(code, "synthesizing speech"))
    return;

  free_chunk();
  SDL_RWops* rw = SDL_RWFromConstMem(wav, (int)wav_len);
  if (rw) {
    g_chunk = Mix_LoadWAV_RW(rw, 1);  // 1: SDL_mixer closes the RWops
    if (g_chunk) {
      g_channel = Mix_PlayChannel(-1, g_chunk, 0);
      if (g_channel < 0) {
        LOG(WARNING) << "Tts: Mix_PlayChannel failed: " << Mix_GetError();
        Mix_FreeChunk(g_chunk);
        g_chunk = nullptr;
      }
    } else {
      LOG(WARNING) << "Tts: failed to decode synthesized speech: "
                   << Mix_GetError();
    }
  } else {
    LOG(WARNING) << "Tts: SDL_RWFromConstMem failed: " << SDL_GetError();
  }
  p_wav_free(wav);
}

void stop_fn(void) {
  free_chunk();
}

const RgssTtsBackend kBackend = {available_fn, speak_fn, stop_fn};

}  // namespace

#endif  // RGSS_TTS_HAVE_DLOPEN

// Install the VOICEVOX backend and eagerly load Zundamon's voice model. Only
// called from src/main.cxx when --zundamon_tts is passed, so a normal run
// pays no cost at all -- no dlopen, no ONNX Runtime session, nothing.
extern "C" void rgss_tts_init(void) {
#if defined(RGSS_TTS_HAVE_DLOPEN)
  rgss_tts_install_backend(&kBackend);
  ensure_init();
#else
  LOG(WARNING) << "Tts: --zundamon_tts has no backend on this build (VOICEVOX "
                  "CORE integration is desktop-only)";
#endif
}

extern "C" void rgss_tts_shutdown(void) {
#if defined(RGSS_TTS_HAVE_DLOPEN)
  if (!g_init_attempted)
    return;
  rgss_tts_install_backend(nullptr);
  free_chunk();
  if (g_model) {
    p_voice_model_file_delete(g_model);
    g_model = nullptr;
  }
  if (g_synthesizer) {
    p_synthesizer_delete(g_synthesizer);
    g_synthesizer = nullptr;
  }
  if (g_open_jtalk) {
    p_open_jtalk_rc_delete(g_open_jtalk);
    g_open_jtalk = nullptr;
  }
  if (g_core) {
    dlclose(g_core);
    g_core = nullptr;
  }
  g_available = false;
  g_init_attempted = false;
#endif
}
