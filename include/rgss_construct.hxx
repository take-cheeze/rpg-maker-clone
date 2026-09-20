// Direct-construction entry points for bc2cpp's own devirtualized `.new`
// (tools/bc2cpp/bc2cpp.rb's compile_send, NATIVE_CONSTRUCT_TARGETS) -- the
// hand-written native constructors for RGSS value/display classes, called
// directly in place of Class#new's own allocate+initialize dispatch chain
// when a compiled `.new` call site's receiver is provably one of these
// classes. Defined in mruby-rgss/src/lib.cxx (namespace `rgss`, file
// scope -- NOT the anonymous namespace, so plain C++ linkage reaches
// every translation unit that includes this header, with no `extern "C"`
// escape hatch needed); the RClass* each guard compares against comes
// from the matching `native_*_class` accessor below, captured once at
// gem-init time, independent of whatever the constant table says right
// now (see lib.cxx's own comment on those globals).
#pragma once

#include <mruby.h>

namespace rgss {

RClass* native_rect_class(void);
RClass* native_color_class(void);
RClass* native_tone_class(void);
RClass* native_sprite_class(void);

mrb_value rect_new_direct(mrb_state* M,
                          RClass* klass,
                          mrb_int x,
                          mrb_int y,
                          mrb_int w,
                          mrb_int h);
mrb_value color_new_direct(mrb_state* M,
                           RClass* klass,
                           mrb_float r,
                           mrb_float g,
                           mrb_float b,
                           mrb_float a);
mrb_value tone_new_direct(mrb_state* M,
                          RClass* klass,
                          mrb_float r,
                          mrb_float g,
                          mrb_float b,
                          mrb_float gray);
mrb_value sprite_new_direct(mrb_state* M, RClass* klass, mrb_value viewport);

}  // namespace rgss

// Bitmap's integer-size constructor keeps C linkage because its generated
// call site uses the C entry points defined in mruby-rgss/src/lib.cxx.
extern "C" RClass* rgss_native_bitmap_class(void);
extern "C" mrb_value rgss_bitmap_new_direct(mrb_state* M,
                                            RClass* klass,
                                            mrb_int w,
                                            mrb_int h);
