#pragma once

#include <cfloat>
#include <cstdint>

// mruby rounds every Float operation to mrb_float; so must this loop.
static_assert(FLT_EVAL_METHOD == 0, "excess-precision float evaluation");

namespace rpg2k {

enum class ExpCurveStatus { ok, overflow };

struct ExpCurveResult {
  ExpCurveStatus status;
  int64_t value;
};

// A product through memory, so the compiler cannot fuse it with the add that
// follows (an FMA rounds once where the VM rounded twice, and the results
// move).
template <class F>
F rounded_product(F a, F b) {
  volatile F p = a * b;
  return p;
}

// The RPG2000 EXP curve (Game::Actor#calc_exp) on F, mrb_float in the native.
// Each step is the Ruby loop it replaced, one rounded operation at a time:
// scripts/rpg2k/exp_curve_check.rb holds it to that Ruby over every editor
// input. overflow is where the Ruby total passed 64 bits; from Integer inputs a
// term passes 64 bits before it can reach Infinity or NaN.
template <class F>
ExpCurveResult exp_curve_loop(int64_t basic,
                              int64_t increase,
                              int64_t correction_in,
                              int64_t n,
                              int64_t cap) {
  F base = static_cast<F>(basic);
  F inflation = F(1.5) + rounded_product(static_cast<F>(increase), F(0.01));
  const F correction = static_cast<F>(correction_in);
  const F decay = rounded_product(static_cast<F>(n + 1), F(0.002)) + F(0.8);
  int64_t result = 0;
  for (int64_t i = 0; i < n; ++i) {
    const F term = correction + base;
    // With base, correction >= 0 and inflation >= 1 no later term is negative,
    // so a total that reaches the cap stays there, and every result below it
    // fits 32 bits.
    if (result >= 0 && base >= 0 && correction >= 0 && inflation >= 1 &&
        static_cast<F>(result) + term >= static_cast<F>(cap)) {
      return {ExpCurveStatus::ok, cap};
    }
    if (!(term >= F(-9223372036854775808.0) && term < F(9223372036854775808.0)))
      return {ExpCurveStatus::overflow, 0};
    if (__builtin_add_overflow(result, static_cast<int64_t>(term), &result))
      return {ExpCurveStatus::overflow, 0};
    base *= inflation;
    inflation = rounded_product(decay, inflation - F(1)) + F(1);
  }
  return {ExpCurveStatus::ok, result > cap ? cap : result};
}

}  // namespace rpg2k
