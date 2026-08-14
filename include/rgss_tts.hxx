// Text-to-speech backend interface shared between the mruby-rgss gem and the
// executable, mirroring rgss_audio.hxx's split: the gem must not depend on
// VOICEVOX CORE or SDL, so RGSS::Tts's native methods (mruby-rgss/src/tts.cxx)
// call through this function-pointer table instead of touching either
// directly, and the executable installs the real implementation
// (src/voicevox_tts.cxx) at startup via rgss_tts_install_backend(). When no
// backend is installed (tests, a build without --zundamon_tts, or a platform
// this feature does not cover) every Tts call is a graceful no-op.
//
// This header intentionally uses only plain C types so both sides can include
// it without pulling in mruby, SDL or VOICEVOX CORE headers.

#ifndef RGSS_TTS_HXX
#define RGSS_TTS_HXX

#ifdef __cplusplus
extern "C" {
#endif

struct RgssTtsBackend {
  // Whether synthesis is actually usable -- the VOICEVOX CORE library, its
  // ONNX Runtime, the Open JTalk dictionary and the Zundamon voice model all
  // loaded. False for any missing/broken piece (see src/voicevox_tts.cxx),
  // which is what RGSS::Tts.available? reports so calling code can skip
  // speak() rather than have it silently do nothing every time.
  int (*available)(void);

  // Synthesize `utf8_text` in Zundamon's voice and play it once, replacing
  // whatever utterance is still playing (a new message page's narration
  // supersedes the previous one, the same way starting a new BGM replaces the
  // one already playing). A no-op if synthesis or playback fails; the failure
  // is logged, not raised, so a missing/broken TTS stack never interrupts the
  // game.
  void (*speak)(const char* utf8_text);

  // Stop whatever utterance is currently playing.
  void (*stop)(void);
};

// Install (copy) the backend, or detach it by passing null. Safe to call
// before mruby is initialised; the table is stored in a plain global.
void rgss_tts_install_backend(const struct RgssTtsBackend* backend);

#ifdef __cplusplus
}
#endif

#endif  // RGSS_TTS_HXX
