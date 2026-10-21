#pragma once

#include <mruby.h>
#include <mruby/array.h>

// Element access for an Array value. Project code reads an Array's length and
// elements through these, so a change to how an Array keeps its elements edits
// this header rather than every call site. Both forward to mruby's own macros.

inline mrb_int ary_size(mrb_value a) {
  return RARRAY_LEN(a);
}

inline mrb_value* ary_items(mrb_value a) {
  return RARRAY_PTR(a);
}
