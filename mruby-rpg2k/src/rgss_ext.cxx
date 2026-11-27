#include <mruby.h>
#include <mruby/class.h>

#include <cstdint>

#include "exp_curve.hxx"

namespace {

// INT32_ARITH: engine arithmetic whose intermediate leaves 32 bits on real
// data, done in int64_t, so a 32-bit mrb_int build needs no bignum.
mrb_value saturated(mrb_state* M, int64_t v) {
  if (v > INT32_MAX)
    v = INT32_MAX;
  if (v < INT32_MIN)
    v = INT32_MIN;
  return mrb_int_value(M, static_cast<mrb_int>(v));
}

// Game.var_op(op, cur, val): Control Variables' operation (0 =, 1 +, 2 -, 3 *,
// 4 /, 5 %; any other op keeps cur), saturated to 32 bits. / and % truncate
// toward zero as RPG_RT's C++ does (mruby's floor); a zero divisor leaves /
// unchanged and makes % zero, as the reference implementation does. The caller
// clamps to the variable range, inside 32 bits, so the stored value is the
// clamp of the exact result. Operands past 32 bits (a 64-bit mrb_int only)
// are saturated first.
mrb_value var_op(mrb_state* M, mrb_value) {
  mrb_int op, cur, val;
  mrb_get_args(M, "iii", &op, &cur, &val);
  const int64_t a = cur < INT32_MIN   ? INT32_MIN
                    : cur > INT32_MAX ? INT32_MAX
                                      : cur;
  const int64_t b = val < INT32_MIN   ? INT32_MIN
                    : val > INT32_MAX ? INT32_MAX
                                      : val;
  switch (op) {
    case 0:
      return saturated(M, b);
    case 1:
      return saturated(M, a + b);
    case 2:
      return saturated(M, a - b);
    case 3:
      return saturated(M, a * b);
    case 4:
      return saturated(M, b == 0 ? a : a / b);
    case 5:
      return saturated(M, b == 0 ? 0 : a % b);
    default:
      return saturated(M, a);
  }
}

// Game.mul_div(a, b, c): (a * b) / c floored, as Integer#/ does, the product
// in 64 bits. A product or result past 32 bits raises RangeError.
mrb_value mul_div(mrb_state* M, mrb_value) {
  mrb_int a, b, c;
  mrb_get_args(M, "iii", &a, &b, &c);
  if (c == 0) {
    mrb_raise(M, mrb_exc_get_id(M, MRB_ERROR_SYM(ZeroDivisionError)),
              "divided by 0");
  }
  int64_t p;
  if (a < INT32_MIN || a > INT32_MAX || b < INT32_MIN || b > INT32_MAX ||
      __builtin_mul_overflow(static_cast<int64_t>(a), static_cast<int64_t>(b),
                             &p)) {
    mrb_raise(M, mrb_exc_get_id(M, MRB_ERROR_SYM(RangeError)),
              "integer overflow in mul_div");
  }
  int64_t q = p / c;
  if (p % c != 0 && (p < 0) != (c < 0))
    --q;
  if (q > INT32_MAX || q < INT32_MIN) {
    mrb_raise(M, mrb_exc_get_id(M, MRB_ERROR_SYM(RangeError)),
              "integer overflow in mul_div");
  }
  return mrb_int_value(M, static_cast<mrb_int>(q));
}

#ifndef MRB_NO_FLOAT
// Game.exp_curve(basic, increase, correction, n, cap): Actor#calc_exp's RPG2000
// curve (see exp_curve.hxx) in C locals, so no step boxes a Float.
mrb_value exp_curve(mrb_state* M, mrb_value) {
  mrb_int basic, increase, correction, n, cap;
  mrb_get_args(M, "iiiii", &basic, &increase, &correction, &n, &cap);
  const rpg2k::ExpCurveResult r =
      rpg2k::exp_curve_loop<mrb_float>(basic, increase, correction, n, cap);
  if (r.status == rpg2k::ExpCurveStatus::not_finite) {
    mrb_raise(M, mrb_exc_get_id(M, MRB_ERROR_SYM(FloatDomainError)),
              "EXP curve term is not finite");
  }
  if (r.status == rpg2k::ExpCurveStatus::overflow || r.value < MRB_INT_MIN) {
    mrb_raise(M, mrb_exc_get_id(M, MRB_ERROR_SYM(RangeError)),
              "integer overflow in exp_curve");
  }
  return mrb_int_value(M, static_cast<mrb_int>(r.value));
}
#endif

}  // namespace

extern "C" void mrb_mruby_rpg2k_gem_init(mrb_state* M) {
  RClass* game = mrb_define_module(M, "Game");
  mrb_define_module_function(M, game, "var_op", var_op, MRB_ARGS_REQ(3));
  mrb_define_module_function(M, game, "mul_div", mul_div, MRB_ARGS_REQ(3));
#ifndef MRB_NO_FLOAT
  mrb_define_module_function(M, game, "exp_curve", exp_curve, MRB_ARGS_REQ(5));
#endif
}

extern "C" void mrb_mruby_rpg2k_gem_final(mrb_state* M) {}
