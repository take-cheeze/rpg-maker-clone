/*
** Minimal Math module for the Wio Terminal build.
**
** mruby's core mruby-math registers ~30 Math functions (erf/erfc, cbrt,
** the hyperbolics and their inverses, log2/log10/log1p/expm1, hypot, ...),
** and because gem init takes each one's address, every libm routine behind
** them is linked whether or not anything calls it. On wio nothing can call
** them except the engine's own gems -- RPG2000/2003 games carry no Ruby and
** the build links no compiler/eval -- and those only use Math::PI and
** Math.sin. scripts/wio_dropped_gems_check.rb fails CI if a wio-linked gem
** starts using any other Math member; add it here (mirroring
** 3rd/mruby/mrbgems/mruby-math/src/math.c) when it does. See docs/adr/0204.
*/

#include <math.h>

#include <mruby.h>
#include <mruby/presym.h>

#ifdef MRB_NO_FLOAT
#error Math conflicts with 'MRB_NO_FLOAT' configuration
#endif

static mrb_value math_sin(mrb_state* mrb, mrb_value obj) {
  return mrb_float_value(mrb, sin(mrb_as_float(mrb, mrb_get_arg1(mrb))));
}

void mrb_mruby_math_wio_gem_init(mrb_state* mrb) {
  struct RClass* math = mrb_define_module_id(mrb, MRB_SYM(Math));

  mrb_define_class_under_id(mrb, math, MRB_SYM(DomainError), E_STANDARD_ERROR);
  mrb_define_const_id(mrb, math, MRB_SYM(PI), mrb_float_value(mrb, M_PI));
  mrb_define_const_id(mrb, math, MRB_SYM(E), mrb_float_value(mrb, M_E));
  mrb_define_module_function_id(mrb, math, MRB_SYM(sin), math_sin,
                                MRB_ARGS_REQ(1));
}

void mrb_mruby_math_wio_gem_final(mrb_state* mrb) {}
