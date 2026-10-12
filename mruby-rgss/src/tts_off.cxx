// Stand-in for tts.cxx in the builds that can never have a RGSS::Tts backend
// (every build but the desktop "host" one, see tools/rgss_tts_config.rb and
// ADR 0417): mruby-rgss/mrbgem.rake compiles exactly one of the two. lib.cxx
// calls rgss_tts_define unconditionally -- and is deliberately left alone,
// because tools/bc2cpp/native_class_results.rb pins its digest -- so this
// registers nothing: there is no RGSS::Tts constant, no native method, and no
// backend table in such a build.

#include <mruby.h>
#include <mruby/class.h>

void rgss_tts_define(mrb_state* M, RClass* rgss) {
  (void)M;
  (void)rgss;
}
