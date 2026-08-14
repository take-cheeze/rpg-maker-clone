// RGSS::Tts native methods (gem side): Zundamon (ずんだもん) text-to-speech
// narration, used by the rpg2k message window (mruby-rpg2k/mrblib/scene/
// map.rb) to read a Show Text page's plain, fully-expanded text aloud.
//
// These are thin forwarders onto an RgssTtsBackend function table (see
// include/rgss_tts.hxx), mirroring audio.cxx's split from RgssAudioBackend:
// the executable installs a VOICEVOX CORE-based backend at startup
// (src/voicevox_tts.cxx) only when --zundamon_tts was passed and the assets
// are present; otherwise -- the common case -- every method here is a
// graceful no-op, so a script calling RGSS::Tts never has to check whether
// the feature is even compiled in. Keeping VOICEVOX CORE out of the gem is
// deliberate for the same reason SDL is kept out of it: the gem is also built
// for the terminal-only and emscripten variants and the standalone `rake
// test` binary, none of which link it.

#include <mruby.h>
#include <mruby/class.h>
#include <mruby/string.h>

#include "rgss_tts.hxx"

namespace {

// The installed backend, or an all-null table when nothing is installed.
// Every entry point checks the relevant pointer before calling, so the
// uninstalled state is a safe no-op.
RgssTtsBackend g_backend = {};

mrb_value tts_available(mrb_state* M, mrb_value self) {
  bool ok = g_backend.available && g_backend.available() != 0;
  return mrb_bool_value(ok);
}

mrb_value tts_speak(mrb_state* M, mrb_value self) {
  const char* text;
  mrb_get_args(M, "z", &text);
  if (g_backend.speak)
    g_backend.speak(text);
  return mrb_nil_value();
}

mrb_value tts_stop(mrb_state* M, mrb_value self) {
  if (g_backend.stop)
    g_backend.stop();
  return mrb_nil_value();
}

}  // namespace

// Install (copy) the backend table, or clear it when passed null.
extern "C" void rgss_tts_install_backend(const RgssTtsBackend* backend) {
  if (backend)
    g_backend = *backend;
  else
    g_backend = RgssTtsBackend{};
}

// Define the native RGSS::Tts module methods. Called from the gem init in
// lib.cxx.
void rgss_tts_define(mrb_state* M, RClass* rgss) {
  RClass* tts = mrb_define_module_under(M, rgss, "Tts");
  mrb_define_module_function(M, tts, "available?", tts_available,
                             MRB_ARGS_NONE());
  mrb_define_module_function(M, tts, "speak", tts_speak, MRB_ARGS_REQ(1));
  mrb_define_module_function(M, tts, "stop", tts_stop, MRB_ARGS_NONE());
}
