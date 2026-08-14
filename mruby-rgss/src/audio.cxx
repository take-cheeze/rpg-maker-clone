// RGSS::Audio native methods (gem side).
//
// These are thin forwarders onto an RgssAudioBackend function table (see
// include/rgss_audio.hxx). The executable installs an SDL_mixer-based backend
// at startup (src/sdl_audio.cxx); when none is installed — the standalone
// `rake test` binary, or any build without an audio library — every method is
// a graceful no-op so scripts calling the standard Audio API never crash.
//
// The Ruby layer in mruby-rgss/mrblib/lib.rb resolves a game-supplied filename
// (searching GAME_DIR/RTP_DIR, the Music/Sound/Audio sub-folders and the known
// extensions) to a real path before calling these, mirroring how Bitmap loads
// image assets. Keeping SDL out of the gem is deliberate: the gem is also built
// for the terminal-only and emscripten variants and must not pull SDL onto its
// include/link path.

#include <mruby.h>
#include <mruby/class.h>
#include <mruby/string.h>

#include "rgss_audio.hxx"

namespace {

// The installed backend, or an all-null table when nothing is installed. Every
// entry point checks the relevant pointer before calling, so the uninstalled
// state is a safe no-op.
RgssAudioBackend g_backend = {};

// Read (path, volume=100, pitch=100) for the *_play methods.
void get_play_args(mrb_state* M,
                   const char** path,
                   mrb_int* volume,
                   mrb_int* pitch) {
  *volume = 100;
  *pitch = 100;
  mrb_get_args(M, "z|ii", path, volume, pitch);
}

// The *_play_mem twins take (name, bytes, volume=100, pitch=100). `name` is an
// archive entry name rather than a path -- see include/rgss_audio.hxx.
using PlayMemFn = void (*)(const char*, const void*, int, int, int);

mrb_value play_mem(mrb_state* M, PlayMemFn fn) {
  const char* name;
  const char* data;
  mrb_int size;
  mrb_int volume = 100, pitch = 100;
  mrb_get_args(M, "zs|ii", &name, &data, &size, &volume, &pitch);
  if (fn && size > 0)
    fn(name, data, (int)size, (int)volume, (int)pitch);
  return mrb_nil_value();
}

mrb_value bgm_play(mrb_state* M, mrb_value self) {
  const char* path;
  mrb_int volume, pitch;
  get_play_args(M, &path, &volume, &pitch);
  if (g_backend.bgm_play)
    g_backend.bgm_play(path, (int)volume, (int)pitch);
  return mrb_nil_value();
}

mrb_value bgm_volume(mrb_state* M, mrb_value self) {
  mrb_int volume;
  mrb_get_args(M, "i", &volume);
  if (g_backend.bgm_volume)
    g_backend.bgm_volume((int)volume);
  return mrb_nil_value();
}

mrb_value bgm_pan(mrb_state* M, mrb_value self) {
  mrb_int pan;
  mrb_get_args(M, "i", &pan);
  if (g_backend.bgm_pan)
    g_backend.bgm_pan((int)pan);
  return mrb_nil_value();
}

mrb_value bgm_stop(mrb_state* M, mrb_value self) {
  if (g_backend.bgm_stop)
    g_backend.bgm_stop();
  return mrb_nil_value();
}

mrb_value bgm_fade(mrb_state* M, mrb_value self) {
  mrb_int ms;
  mrb_get_args(M, "i", &ms);
  if (g_backend.bgm_fade)
    g_backend.bgm_fade((int)ms);
  return mrb_nil_value();
}

mrb_value bgm_pos(mrb_state* M, mrb_value self) {
  int pos = g_backend.bgm_pos ? g_backend.bgm_pos() : 0;
  return mrb_fixnum_value(pos);
}

mrb_value bgs_play(mrb_state* M, mrb_value self) {
  const char* path;
  mrb_int volume, pitch;
  get_play_args(M, &path, &volume, &pitch);
  if (g_backend.bgs_play)
    g_backend.bgs_play(path, (int)volume, (int)pitch);
  return mrb_nil_value();
}

mrb_value bgs_stop(mrb_state* M, mrb_value self) {
  if (g_backend.bgs_stop)
    g_backend.bgs_stop();
  return mrb_nil_value();
}

mrb_value bgs_fade(mrb_state* M, mrb_value self) {
  mrb_int ms;
  mrb_get_args(M, "i", &ms);
  if (g_backend.bgs_fade)
    g_backend.bgs_fade((int)ms);
  return mrb_nil_value();
}

mrb_value bgs_pos(mrb_state* M, mrb_value self) {
  int pos = g_backend.bgs_pos ? g_backend.bgs_pos() : 0;
  return mrb_fixnum_value(pos);
}

mrb_value me_play(mrb_state* M, mrb_value self) {
  const char* path;
  mrb_int volume, pitch;
  get_play_args(M, &path, &volume, &pitch);
  if (g_backend.me_play)
    g_backend.me_play(path, (int)volume, (int)pitch);
  return mrb_nil_value();
}

mrb_value me_stop(mrb_state* M, mrb_value self) {
  if (g_backend.me_stop)
    g_backend.me_stop();
  return mrb_nil_value();
}

mrb_value me_fade(mrb_state* M, mrb_value self) {
  mrb_int ms;
  mrb_get_args(M, "i", &ms);
  if (g_backend.me_fade)
    g_backend.me_fade((int)ms);
  return mrb_nil_value();
}

mrb_value se_play(mrb_state* M, mrb_value self) {
  const char* path;
  mrb_int volume, pitch;
  get_play_args(M, &path, &volume, &pitch);
  if (g_backend.se_play)
    g_backend.se_play(path, (int)volume, (int)pitch);
  return mrb_nil_value();
}

mrb_value se_stop(mrb_state* M, mrb_value self) {
  if (g_backend.se_stop)
    g_backend.se_stop();
  return mrb_nil_value();
}

// True only when the backend resolved a MIDI patch set, so a .mid BGM/ME will
// actually be audible. False with no backend installed (tests, no-audio builds)
// and false when the backend found no TiMidity configuration.
mrb_value midi_available(mrb_state* M, mrb_value self) {
  bool ok = g_backend.midi_available && g_backend.midi_available() != 0;
  return mrb_bool_value(ok);
}

mrb_value audio_update(mrb_state* M, mrb_value self) {
  if (g_backend.update)
    g_backend.update();
  return mrb_nil_value();
}

mrb_value bgm_play_mem(mrb_state* M, mrb_value self) {
  return play_mem(M, g_backend.bgm_play_mem);
}

mrb_value bgs_play_mem(mrb_state* M, mrb_value self) {
  return play_mem(M, g_backend.bgs_play_mem);
}

mrb_value me_play_mem(mrb_state* M, mrb_value self) {
  return play_mem(M, g_backend.me_play_mem);
}

mrb_value se_play_mem(mrb_state* M, mrb_value self) {
  return play_mem(M, g_backend.se_play_mem);
}

// Whether this build can play audio it did not read from a file. False with no
// backend installed (the `rake test` binary, a build with no audio library), so
// the Ruby layer can say once that a packed game will be silent instead of
// dropping every play on the floor without a word.
mrb_value can_play_mem(mrb_state* M, mrb_value self) {
  return mrb_bool_value(g_backend.bgm_play_mem != nullptr);
}

}  // namespace

// Install (copy) the backend table, or clear it when passed null.
extern "C" void rgss_audio_install_backend(const RgssAudioBackend* backend) {
  if (backend)
    g_backend = *backend;
  else
    g_backend = RgssAudioBackend{};
}

// Drive the backend's per-frame work. Called from Graphics.update (lib.cxx) so
// deferred behaviour (BGM resuming after a music effect) advances even if no
// Ruby code touches Audio this frame.
extern "C" void rgss_audio_frame(void) {
  if (g_backend.update)
    g_backend.update();
}

// Define the native RGSS::Audio module methods. Called from the gem init in
// lib.cxx. The public, path-resolving API in lib.rb reopens this module and
// delegates to these underscore-prefixed primitives.
void rgss_audio_define(mrb_state* M, RClass* rgss) {
  RClass* audio = mrb_define_module_under(M, rgss, "Audio");
  mrb_define_module_function(M, audio, "_bgm_play", bgm_play,
                             MRB_ARGS_ARG(1, 2));
  mrb_define_module_function(M, audio, "_bgm_volume", bgm_volume,
                             MRB_ARGS_REQ(1));
  mrb_define_module_function(M, audio, "_bgm_pan", bgm_pan, MRB_ARGS_REQ(1));
  mrb_define_module_function(M, audio, "_bgm_stop", bgm_stop, MRB_ARGS_NONE());
  mrb_define_module_function(M, audio, "_bgm_fade", bgm_fade, MRB_ARGS_REQ(1));
  mrb_define_module_function(M, audio, "_bgm_pos", bgm_pos, MRB_ARGS_NONE());
  mrb_define_module_function(M, audio, "_bgs_play", bgs_play,
                             MRB_ARGS_ARG(1, 2));
  mrb_define_module_function(M, audio, "_bgs_stop", bgs_stop, MRB_ARGS_NONE());
  mrb_define_module_function(M, audio, "_bgs_fade", bgs_fade, MRB_ARGS_REQ(1));
  mrb_define_module_function(M, audio, "_bgs_pos", bgs_pos, MRB_ARGS_NONE());
  mrb_define_module_function(M, audio, "_me_play", me_play, MRB_ARGS_ARG(1, 2));
  mrb_define_module_function(M, audio, "_me_stop", me_stop, MRB_ARGS_NONE());
  mrb_define_module_function(M, audio, "_me_fade", me_fade, MRB_ARGS_REQ(1));
  mrb_define_module_function(M, audio, "_se_play", se_play, MRB_ARGS_ARG(1, 2));
  mrb_define_module_function(M, audio, "_se_stop", se_stop, MRB_ARGS_NONE());
  mrb_define_module_function(M, audio, "_update", audio_update,
                             MRB_ARGS_NONE());
  // Play from encoded bytes: how a release that packs its Audio/ tree into an
  // encrypted RGSSAD archive is heard at all (see RGSS.asset_archive).
  mrb_define_module_function(M, audio, "_bgm_play_mem", bgm_play_mem,
                             MRB_ARGS_ARG(2, 2));
  mrb_define_module_function(M, audio, "_bgs_play_mem", bgs_play_mem,
                             MRB_ARGS_ARG(2, 2));
  mrb_define_module_function(M, audio, "_me_play_mem", me_play_mem,
                             MRB_ARGS_ARG(2, 2));
  mrb_define_module_function(M, audio, "_se_play_mem", se_play_mem,
                             MRB_ARGS_ARG(2, 2));
  mrb_define_module_function(M, audio, "_midi_available", midi_available,
                             MRB_ARGS_NONE());
  mrb_define_module_function(M, audio, "_can_play_mem?", can_play_mem,
                             MRB_ARGS_NONE());
}
