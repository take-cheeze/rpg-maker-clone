// Swaps AOT-compiled C++ bodies in for all 17 of RGSS::Sprite's own real
// bytecode-defined methods (docs/adr/0139) -- every plain Ruby reader
// mruby-rgss/mrblib/lib.rb reopens the native Sprite class with, made
// possible by this same follow-up's own JMPNIL/LOADL opcode additions
// (opacity/zoom_x/zoom_y's own `@ivar.nil? ? default : @ivar` shape) and
// GETCONST owner-scope-first fix (tone/color/src_rect's own
// `Tone.new(...)`/`Color.new(...)`/`Rect.new(...)` -- each of those three
// classes is defined on the *enclosing* RGSS module, not on Sprite itself
// nor Object, a real bug the original single-scope-from-Object GETCONST
// codegen would have hit for exactly these three methods). mruby-rgss
// (this gem's own add_dependency) has already run its full gem init -- C
// hook *and* mrblib -- by the time this gem's own init runs, so Sprite is
// guaranteed to already exist below, already a native MRB_TT_DATA class.
//
// No ivar embedding here: all 17 compiled methods are pure readers (the
// real writers -- `x=`/`y=`/`opacity=`/... -- are native, defined in
// mruby-rgss/src/lib.cxx, invisible to bc2cpp the same way every other
// native method there is), so bc2cpp's own drop_unsafe_embeddings guard
// never even considers RGSS::Sprite (no compiled #initialize to allocate
// a struct in) -- every GETIV/SETIV below stays on the ordinary dynamic
// iv_tbl, exactly matching the interpreter's own behavior and coexisting
// fine with Sprite's native RData payload (mruby/data.h: an RData carries
// both a `data` pointer and a normal `iv` table).
//
// RGSS::Plane (docs/adr/0139's own follow-up, this gem's second owner)
// gets the same treatment for its own 6 real bytecode-defined methods
// (opacity/zoom_x/zoom_y/blend_type/tone/color) -- plain Ruby readers
// answering RGSS defaults for ivars only Plane's native #initialize
// (mruby-rgss/src/lib.cxx) ever sets, the exact same shape as Sprite's
// own identically-named methods above, reusing the same JMPNIL/ternary,
// `||`, and owner-scope-first GETCONST codegen with zero new bc2cpp.rb
// work. `attr_reader :bitmap, :ox, :oy, :z, :viewport` stays native/
// uncompiled, as always. Plane has no #initialize of its own at all (the
// native one is invisible to bc2cpp, same as every other native method),
// so bc2cpp's own drop_unsafe_embeddings guard never even considers
// RGSS::Plane either -- confirmed directly against the real diagnostic:
// it never appears in bc2cpp's own "classes needing
// MRB_SET_INSTANCE_TT" listing. Every GETIV/SETIV below stays on the
// ordinary dynamic iv_tbl, same as Sprite.
#include <mruby.h>
#include <mruby/class.h>

// Generated at build time by tools/bc2cpp/bc2cpp.rb from mruby-rgss's own
// real mrblib/lib.rb (mrbgem.rake's own `file` rule runs it before this
// translation unit is compiled).
#include "rgss_compiled_gen.cpp"

extern "C" void mrb_mruby_rgss_compiled_gem_init(mrb_state* M) {
  RClass* rgss = mrb_module_get(M, "RGSS");
  RClass* sprite = mrb_class_get_under(M, rgss, "Sprite");

  mrb_define_method(M, sprite, "opacity", RGSS__Sprite_opacity,
                    MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "zoom_x", RGSS__Sprite_zoom_x, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "zoom_y", RGSS__Sprite_zoom_y, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "blend_type", RGSS__Sprite_blend_type,
                    MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "tone", RGSS__Sprite_tone, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "color", RGSS__Sprite_color, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "width", RGSS__Sprite_width, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "height", RGSS__Sprite_height, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "x", RGSS__Sprite_x, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "y", RGSS__Sprite_y, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "z", RGSS__Sprite_z, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "ox", RGSS__Sprite_ox, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "oy", RGSS__Sprite_oy, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "angle", RGSS__Sprite_angle, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "mirror", RGSS__Sprite_mirror, MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "bush_depth", RGSS__Sprite_bush_depth,
                    MRB_ARGS_NONE());
  mrb_define_method(M, sprite, "src_rect", RGSS__Sprite_src_rect,
                    MRB_ARGS_NONE());

  RClass* plane = mrb_class_get_under(M, rgss, "Plane");

  mrb_define_method(M, plane, "opacity", RGSS__Plane_opacity, MRB_ARGS_NONE());
  mrb_define_method(M, plane, "zoom_x", RGSS__Plane_zoom_x, MRB_ARGS_NONE());
  mrb_define_method(M, plane, "zoom_y", RGSS__Plane_zoom_y, MRB_ARGS_NONE());
  mrb_define_method(M, plane, "blend_type", RGSS__Plane_blend_type,
                    MRB_ARGS_NONE());
  mrb_define_method(M, plane, "tone", RGSS__Plane_tone, MRB_ARGS_NONE());
  mrb_define_method(M, plane, "color", RGSS__Plane_color, MRB_ARGS_NONE());
}

extern "C" void mrb_mruby_rgss_compiled_gem_final(mrb_state*) {}
