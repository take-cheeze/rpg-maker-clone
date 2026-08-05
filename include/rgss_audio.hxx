// Audio backend interface shared between the mruby-rgss gem and the executable.
//
// The gem must not depend on SDL: it is also built for the terminal-only and
// emscripten variants and for the standalone `rake test` binary, none of which
// link an audio library. So RGSS::Audio's native methods (mruby-rgss/src/
// audio.cxx) call through this function-pointer table instead of calling
// SDL_mixer directly, and the executable installs the real implementation
// (src/sdl_audio.cxx) at startup via rgss_audio_install_backend(). When no
// backend is installed (tests, or a build without audio) every Audio call is a
// graceful no-op.
//
// This header intentionally uses only plain C types so both sides can include
// it without pulling in mruby or SDL headers.

#ifndef RGSS_AUDIO_HXX
#define RGSS_AUDIO_HXX

#ifdef __cplusplus
extern "C" {
#endif

// Playback back-end. Paths are already resolved to real files on disk by the
// Ruby layer (see mruby-rgss/mrblib/lib.rb); volume is 0..100 and pitch is a
// percentage (100 = normal). Any pointer may be null, in which case that
// operation is skipped.
//
// Each *_play also has a *_play_mem twin taking the encoded bytes directly.
// That is how a released game's audio plays: it ships one encrypted RGSSAD
// archive holding its whole Audio/ tree with nothing loose on disk, so there is
// no path to hand over (see RGSS.asset_archive). `name` is not a file — it is
// the archive entry name, used as the sample cache key and in diagnostics. The
// bytes belong to the caller and must be copied by any backend that needs them
// to outlive the call.
struct RgssAudioBackend {
  // Background music: a single looping stream. Starting a new one replaces the
  // current music.
  void (*bgm_play)(const char* path, int volume, int pitch);
  void (*bgm_stop)(void);
  void (*bgm_fade)(int ms);
  // Current playback position of the BGM, in milliseconds (0 if unknown).
  int (*bgm_pos)(void);

  // Background sound: a single looping ambience running alongside the music.
  void (*bgs_play)(const char* path, int volume, int pitch);
  void (*bgs_stop)(void);
  void (*bgs_fade)(int ms);
  int (*bgs_pos)(void);

  // Music effect: plays once over the music, then the interrupted BGM resumes.
  void (*me_play)(const char* path, int volume, int pitch);
  void (*me_stop)(void);
  void (*me_fade)(int ms);

  // Sound effect: a one-shot sample; several can overlap.
  void (*se_play)(const char* path, int volume, int pitch);
  void (*se_stop)(void);

  // Called once per frame from Graphics.update so the backend can drive
  // deferred work (e.g. resuming the BGM after a music effect finishes).
  // May be null.
  void (*update)(void);

  // The same four, from encoded bytes rather than a file. See the note above.
  void (*bgm_play_mem)(const char* name,
                       const void* data,
                       int size,
                       int volume,
                       int pitch);
  void (*bgs_play_mem)(const char* name,
                       const void* data,
                       int size,
                       int volume,
                       int pitch);
  void (*me_play_mem)(const char* name,
                      const void* data,
                      int size,
                      int volume,
                      int pitch);
  void (*se_play_mem)(const char* name,
                      const void* data,
                      int size,
                      int volume,
                      int pitch);

  // Non-zero when the backend resolved a MIDI instrument configuration, i.e.
  // when a .mid BGM/ME is expected to be audible rather than silent. Lets the
  // Ruby layer answer Audio.midi_available? instead of guessing. May be null,
  // which reads as "unknown" and is reported as unavailable.
  int (*midi_available)(void);
};

// Install (copy) the audio backend, or detach it by passing null. Safe to call
// before mruby is initialised; the table is stored in a plain global.
void rgss_audio_install_backend(const struct RgssAudioBackend* backend);

#ifdef __cplusplus
}
#endif

#endif  // RGSS_AUDIO_HXX
