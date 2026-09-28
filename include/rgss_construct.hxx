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
RClass* native_bitmap_class(void);
RClass* native_table_class(void);
RClass* native_window_class(void);
RClass* native_viewport_class(void);
RClass* native_plane_class(void);
RClass* native_tilemap_class(void);

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
mrb_value bitmap_new_direct(mrb_state* M, RClass* klass, mrb_int w, mrb_int h);
mrb_value sprite_bitmap_set_direct(mrb_state* M,
                                   mrb_value self,
                                   mrb_value bitmap);
mrb_value bitmap_fill_rect_direct(mrb_state* M,
                                  mrb_value self,
                                  mrb_value x,
                                  mrb_value y,
                                  mrb_value w,
                                  mrb_value h,
                                  mrb_value color);
mrb_value bitmap_blt_direct(mrb_state* M,
                            mrb_value self,
                            mrb_value x,
                            mrb_value y,
                            mrb_value source,
                            mrb_value source_rect,
                            mrb_value opacity,
                            mrb_bool opacity_given);
mrb_value bitmap_stretch_blt_direct(mrb_state* M,
                                    mrb_value self,
                                    mrb_value destination_rect,
                                    mrb_value source,
                                    mrb_value source_rect,
                                    mrb_value opacity,
                                    mrb_bool opacity_given);
mrb_value bitmap_draw_text_direct(mrb_state* M,
                                  mrb_value self,
                                  mrb_int argc,
                                  const mrb_value* argv);
mrb_value bitmap_copy_blt_direct(mrb_state* M,
                                 mrb_value self,
                                 mrb_value x,
                                 mrb_value y,
                                 mrb_value source,
                                 mrb_value source_rect);
mrb_value bitmap_text_size_direct(mrb_state* M, mrb_value self, mrb_value text);
mrb_value bitmap_rect_direct(mrb_state* M, mrb_value self);
mrb_value bitmap_clear_direct(mrb_state* M, mrb_value self);
mrb_value viewport_rect_direct(mrb_state* M, mrb_value self);
mrb_value bitmap_width_direct(mrb_state* M, mrb_value self);
mrb_value bitmap_height_direct(mrb_state* M, mrb_value self);
mrb_value rect_x_direct(mrb_state* M, mrb_value self);
mrb_value rect_y_direct(mrb_state* M, mrb_value self);
mrb_value rect_width_direct(mrb_state* M, mrb_value self);
mrb_value rect_height_direct(mrb_state* M, mrb_value self);
mrb_value color_red_direct(mrb_state* M, mrb_value self);
mrb_value color_green_direct(mrb_state* M, mrb_value self);
mrb_value color_blue_direct(mrb_state* M, mrb_value self);
mrb_value color_alpha_direct(mrb_state* M, mrb_value self);
mrb_value tone_red_direct(mrb_state* M, mrb_value self);
mrb_value tone_green_direct(mrb_state* M, mrb_value self);
mrb_value tone_blue_direct(mrb_state* M, mrb_value self);
mrb_value tone_gray_direct(mrb_state* M, mrb_value self);
mrb_value disposed_direct(mrb_state* M, mrb_value self);
mrb_value visible_direct(mrb_state* M, mrb_value self);
mrb_value sprite_update_direct(mrb_state* M, mrb_value self);
mrb_value viewport_update_direct(mrb_state* M, mrb_value self);
mrb_value window_update_direct(mrb_state* M, mrb_value self);
mrb_value dispose_direct(mrb_state* M, mrb_value self);
mrb_value tilemap_dispose_direct(mrb_state* M, mrb_value self);
mrb_value window_openness_set_direct(mrb_state* M,
                                     mrb_value self,
                                     mrb_value openness);
mrb_value window_tone_set_direct(mrb_state* M, mrb_value self, mrb_value tone);
mrb_value sprite_opacity_set_direct(mrb_state* M,
                                    mrb_value self,
                                    mrb_value opacity);
mrb_value sprite_tone_set_direct(mrb_state* M, mrb_value self, mrb_value tone);
mrb_value viewport_tone_set_direct(mrb_state* M,
                                   mrb_value self,
                                   mrb_value tone);
mrb_value table_new_direct(mrb_state* M,
                           RClass* klass,
                           mrb_int argc,
                           mrb_int x,
                           mrb_int y,
                           mrb_int z);

}  // namespace rgss
