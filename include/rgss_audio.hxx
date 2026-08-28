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
  // current music. pos_ms is RGSS3's mid-track resume position, in
  // milliseconds -- the same unit bgm_pos (below) reports in, so a caller that
  // feeds bgm_pos's own return value back in here round-trips exactly. 0 plays
  // from the beginning, as XP/VX's 3-argument form always did. A backend that
  // cannot seek (or fails to) is expected to fall back to playing from the
  // beginning rather than dropping the play. fadein_ms is not part of any real
  // RGSS Audio.bgm_play -- it carries RPG2000's own Play BGM fade-in
  // parameter (cycle #202). 0 (every RGSS-script call site's implicit value)
  // starts at once, matching every prior build; > 0 is expected to ramp up
  // from silence to `volume` over that many milliseconds instead of jumping
  // there immediately.
  void (*bgm_play)(const char* path,
                   int volume,
                   int pitch,
                   int pos_ms,
                   int fadein_ms);
  // Re-applies volume to the BGM stream already playing, with no restart --
  // unlike bgm_play, which always starts its track over. Used when a Play BGM
  // command re-triggers the file that is already current (RPG_RT re-applies
  // the command's own volume rather than treating the repeat as a no-op).
  // There is no live equivalent for pitch: SDL_mixer cannot re-pitch a
  // playing music stream, only a freshly started one.
  void (*bgm_volume)(int volume);
  // Re-applies stereo balance to the BGM stream already playing, with no
  // restart -- the same live-update shape as bgm_volume. RPG2000's Play BGM
  // balance parameter is 0 (full left) through 100 (full right), 50 centred;
  // pan is 0..100 on that same scale. SDL_mixer has no per-Mix_Music panning
  // API, so the backend implements this via Mix_SetPanning(MIX_CHANNEL_POST,
  // ...), which pans the whole final mixed output (BGM, BGS and SE alike) --
  // see src/sdl_audio.cxx for why that is the only technique that reaches a
  // playing music stream at all.
  void (*bgm_pan)(int pan);
  void (*bgm_stop)(void);
  void (*bgm_fade)(int ms);
  // Current playback position of the BGM, in milliseconds (0 if unknown).
  int (*bgm_pos)(void);

  // Background sound: a single looping ambience running alongside the music.
  void (*bgs_play)(const char* path, int volume, int pitch);
  void (*bgs_stop)(void);
  void (*bgs_fade)(int ms);
  int (*bgs_pos)(void);

  // Music effect: plays once over the music, then the interrupted BGM
  // resumes. fadein_ms is the same fade-in-from-silence duration as
  // bgm_play's, above (RPG2000's own Play BGM / Change System BGM fade-in
  // parameter, reaching the victory fanfare's ME channel this way starting
  // cycle #204) -- SDL_mixer's Mix_FadeInMusic applies identically to a
  // one-shot ME as to a looping BGM, since both are the same underlying
  // Mix_Music stream, just started with a different loop count.
  void (*me_play)(const char* path, int volume, int pitch, int fadein_ms);
  void (*me_stop)(void);
  void (*me_fade)(int ms);

  // Sound effect: a one-shot sample; several can overlap. pan is not part of
  // any real RGSS Audio.se_play signature -- it carries RPG2000's own Play
  // Sound Effect / system-SFX balance parameter (cycle #221, the same shape
  // as bgm_play's fadein_ms above), 0..100 on the same full-left/centre/
  // full-right scale as bgm_pan. Unlike bgm_pan, SDL_mixer's Mix_SetPanning
  // works directly on the Mix_Chunk channel each SE plays on -- no
  // MIX_CHANNEL_POST master-bus trick needed -- so this is genuine
  // per-effect panning, independent of whatever the BGM's own balance is
  // currently set to. 50 (every real-RGSS call site's implicit value, and
  // every RPG2000 SE struct's own schema default) is centred, matching the
  // pre-existing unpanned behaviour exactly.
  void (*se_play)(const char* path, int volume, int pitch, int pan);
  void (*se_stop)(void);

  // Called once per frame from Graphics.update so the backend can drive
  // deferred work (e.g. resuming the BGM after a music effect finishes).
  // May be null.
  void (*update)(void);

  // The same four, from encoded bytes rather than a file. See the note above.
  // bgm_play_mem's pos_ms is the same resume position as bgm_play's, above --
  // this is how a released game (its whole Audio/ tree packed into one
  // archive, nothing loose on disk) actually hears a mid-track resume.
  // fadein_ms is the same fade-in-from-silence duration as bgm_play's, above,
  // reaching a released game's packed archive the same way pos_ms already
  // does.
  void (*bgm_play_mem)(const char* name,
                       const void* data,
                       int size,
                       int volume,
                       int pitch,
                       int pos_ms,
                       int fadein_ms);
  void (*bgs_play_mem)(const char* name,
                       const void* data,
                       int size,
                       int volume,
                       int pitch);
  void (*me_play_mem)(const char* name,
                      const void* data,
                      int size,
                      int volume,
                      int pitch,
                      int fadein_ms);
  void (*se_play_mem)(const char* name,
                      const void* data,
                      int size,
                      int volume,
                      int pitch,
                      int pan);

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
