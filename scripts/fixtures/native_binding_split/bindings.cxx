// Fixture for scripts/native_binding_split_check.rb: one binding per outcome
// of the classification (ADR 0263). The facts next to it were produced with
//   scripts/native_binding_facts.py --config host|wio \
//     scripts/fixtures/native_binding_split/bindings.cxx
// and only change when this file does.
#include <mruby.h>
#include <mruby/string.h>
#include <mruby/variable.h>

namespace {

// splittable: an integer argument
mrb_value set_x(mrb_state* M, mrb_value self) {
  mrb_int x;
  mrb_get_args(M, "i", &x);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@x"), mrb_fixnum_value(x));
  return self;
}

// splittable: two arguments declared in one statement, unnamed self
mrb_value set_pair(mrb_state* M, mrb_value) {
  mrb_int a, b;
  mrb_get_args(M, "ii", &a, &b);
  return mrb_fixnum_value(a + b);
}

// frame-free
mrb_value get_x(mrb_state* M, mrb_value self) {
  return mrb_iv_get(M, self, mrb_intern_lit(M, "@x"));
}

// refused: reads the argument count
mrb_value uses_argc(mrb_state* M, mrb_value self) {
  if (mrb_get_argc(M) == 0)
    return self;
  return mrb_nil_value();
}

// refused: optional argument
mrb_value optional(mrb_state* M, mrb_value self) {
  mrb_int n = 0;
  mrb_get_args(M, "|i", &n);
  return mrb_fixnum_value(n);
}

// refused: work before mrb_get_args (a raise there would change order)
mrb_value work_first(mrb_state* M, mrb_value self) {
  mrb_value first = mrb_iv_get(M, self, mrb_intern_lit(M, "@x"));
  mrb_int n;
  mrb_get_args(M, "i", &n);
  return first;
}

// refused: block
mrb_value with_block(mrb_state* M, mrb_value self) {
  mrb_value blk;
  mrb_get_args(M, "&", &blk);
  return mrb_yield(M, blk, self);
}

mrb_int helper_reads_args(mrb_state* M) {
  mrb_int n;
  mrb_get_args(M, "i", &n);
  return n;
}

// refused: the arguments are read in a callee
mrb_value hidden_get_args(mrb_state* M, mrb_value self) {
  return mrb_fixnum_value(helper_reads_args(M));
}

// refused: goto
mrb_value with_goto(mrb_state* M, mrb_value self) {
  mrb_int n;
  mrb_get_args(M, "i", &n);
  if (n)
    goto done;
  n = 1;
done:
  return mrb_fixnum_value(n);
}

// refused: conditional compilation inside the body
mrb_value ifdef_inside(mrb_state* M, mrb_value self) {
  mrb_int n;
  mrb_get_args(M, "i", &n);
#if defined(WIO_TERMINAL)
  n += 1;
#endif
  return mrb_fixnum_value(n);
}

// refused: the name of the running method is part of the result
mrb_value uses_mid(mrb_state* M, mrb_value self) {
  return mrb_symbol_value(mrb_get_mid(M));
}

// refused: mrb_get_args argument is not a plain local
struct Holder {
  mrb_int slot;
};
mrb_value into_member(mrb_state* M, mrb_value self) {
  Holder h;
  mrb_get_args(M, "i", &h.slot);
  return self;
}

#if !defined(WIO_TERMINAL)
// splittable, compiled off wio only
mrb_value off_wio_set(mrb_state* M, mrb_value self) {
  mrb_bool flag;
  mrb_get_args(M, "b", &flag);
  return mrb_bool_value(flag);
}
#endif

}  // namespace

// A hand-written direct entry point (ADR 0253) and its binding.
namespace rgss {
mrb_value fixture_named_direct(mrb_state* M, mrb_value self, mrb_int v) {
  return mrb_fixnum_value(v);
}
}  // namespace rgss

namespace {
// forwarded: already calls the direct entry point
mrb_value forwards(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  return rgss::fixture_named_direct(M, self, v);
}
}  // namespace

void fixture_init(mrb_state* M) {
  RClass* c = mrb_define_class(M, "Fixture", M->object_class);
  mrb_define_method(M, c, "x=", set_x, MRB_ARGS_REQ(1));
  mrb_define_method(M, c, "pair", set_pair, MRB_ARGS_REQ(2));
  mrb_define_method(M, c, "x", get_x, MRB_ARGS_NONE());
  mrb_define_method(M, c, "argc", uses_argc, MRB_ARGS_ANY());
  mrb_define_method(M, c, "optional", optional, MRB_ARGS_OPT(1));
  mrb_define_method(M, c, "first", work_first, MRB_ARGS_REQ(1));
  mrb_define_method(M, c, "block", with_block, MRB_ARGS_BLOCK());
  mrb_define_method(M, c, "hidden", hidden_get_args, MRB_ARGS_REQ(1));
  mrb_define_method(M, c, "jump", with_goto, MRB_ARGS_REQ(1));
  mrb_define_method(M, c, "ifdef", ifdef_inside, MRB_ARGS_REQ(1));
  mrb_define_method(M, c, "mid", uses_mid, MRB_ARGS_NONE());
  mrb_define_method(M, c, "member", into_member, MRB_ARGS_REQ(1));
#if !defined(WIO_TERMINAL)
  mrb_define_method(M, c, "flag=", off_wio_set, MRB_ARGS_REQ(1));
#endif
  mrb_define_method(M, c, "forwards", forwards, MRB_ARGS_REQ(1));
  mrb_define_class_method(
      M, c, "twice",
      [](mrb_state* M, mrb_value self) -> mrb_value {
        mrb_int n;
        mrb_get_args(M, "i", &n);
        return mrb_fixnum_value(n * 2);
      },
      MRB_ARGS_REQ(1));
  mrb_define_method(
      M, c, "zero", [](mrb_state*, mrb_value self) { return self; },
      MRB_ARGS_NONE());
}
