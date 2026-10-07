# 0372. bc2cpp unboxes a native arm's arguments with mrb_get_args' own conversion

Date: 2026-10-07

## Status

Accepted

## Context

The native direct arms (ADR 0253, 0263, 0281, 0358) call an RGSS native's frame-independent entry point
(`rgss::rect_x_set_direct`, ...). For an `:int` argument they tested `mrb_integer_p` and kept the by-name
`bc2cpp_send` as the else, because a Float, a nil or a String "may not be an Integer". That is the wrong
question. Every such binding is, by construction of `scripts/native_binding_split.rb`,

```cpp
T a; ...; mrb_get_args(M, "<fmt>", &a, ...); return entry(M, self, a, ...);
```

with nothing but declarations before the `mrb_get_args` call, and mruby converts the specifiers as follows
(`3rd/mruby/src/class.c`): `"i"` is exactly `*p = mrb_as_int(mrb, *pickarg)`, `"f"` is
`*p = mrb_as_float(mrb, *pickarg)` and `"b"` is `*boolp = mrb_test(*pickarg)`; each is a function of its one
argument alone. A call site that has proven the receiver's class and the argument count can therefore run
`mrb_as_int(M, reg)` itself and call the entry point. The result is observably the dispatch's, for every
argument: an Integer, a Float (truncation, `RangeError` for 1e30, NaN and infinities), nil, a String, a bool,
an object that is not numeric (`TypeError`), a bignum. The tag test and its else re-derived that.

The same reading exposed an ordering defect in the `:float` arms already shipped: `mrb_as_float(M, a)` was spelled
inside the call expression, whose operand order is unspecified. With two `:float` operands (`_transition_alpha`,
`Color.new`) g++ evaluated the last first, so a call with a nil then a String raised the String's `TypeError`
where dispatch raises the nil's. `Rect.new` unboxed its four `mrb_as_int` operands the same way.

## Decision

**NATIVE_PARAM_UNBOX.** An arm replaces the Integer gate with statements converting each `:int`/`:float`
argument, **in argument order, one statement per conversion** (never inside the call expression):

```cpp
{
  mrb_int bc2cpp_pu5_0 = mrb_as_int(M, r6);
  r5 = rgss::rect_x_set_direct(M, r5, bc2cpp_pu5_0);
}
```

`:bool` is `mrb_test`, `:value` is passed through, and an `:int` the Fixnum proof already covers stays
`mrb_integer(reg)` (pure). The receiver class-identity guard and its else are untouched. The argument count is
the call site's own (`entry.kinds.size == argv.size`, a wrong count has no arm and keeps its send), and the
binding's format has no `|`, so `mrb_get_args` has no count error left to raise at an exact count.

The tag test is dropped only when the name is proven to reach the native (`native_param_unbox_name?`): the
closed world, no alias/Symbol-definition/undef/computed-name installer (`symbol_installed_names`,
`devirt_blocked_name?`), no visibility change or outside source of the name
(`native_exact_direct_name_safe?`), the proof NATIVE_EXACT_DIRECT already needs. Otherwise the arm keeps its
`mrb_integer_p` test and by-name else, and only the `:float` conversions are sequenced. An open world
(no closed-world proof) therefore keeps the old arms.

`Bitmap.new(w, h)` is the one construct whose Ruby `initialize` branches first (`f.kind_of? String`, a
dispatched test): its first argument keeps the `mrb_integer_p` test, which is what selects the `_init_size`
branch, and the second is converted as `"ii"` does. `Rect.new`, `Color.new` and `Tone.new` keep their
unconditional unboxing, now sequenced.

**Audit** (`scripts/bc2cpp_native_param_audit.rb`, run by `scripts/bc2cpp_native_param_unbox_check.rb`):

- the `case 'i'`/`'f'`/`'b'` arms of `mrb_get_args` and the `mrb_as_int`/`mrb_as_float` macros are pinned by a
  digest of their squashed text, so an mruby that changes them fails the check;
- every `NativeDirect::ENTRIES` row with an `:int`/`:float`/`:bool` kind (57 bindings) is registered by a
  binding that parses as the shape above, with the format letters equal to the kinds in order, a constant-only
  declaration prefix, and the table's function (or its `_native_body`) called with the targets in order. A
  binding that fails the audit keeps its gate;
- `"o"` is a passthrough; `S A H n z s` and the rest are not modelled and stay with their guards or by-name sends.

**Kill switch.** `BC2CPP_NATIVE_PARAM_UNBOX=0` restores the previous output exactly (Integer gate, by-name else,
inline float conversions).

## Consequences

- Measured on the wio whole-program census, same tree, kill switch against default: see
  `docs/bc2cpp-dynamic-site-census.md` ("Follow-up: native parameters unboxed").
- A native's `TypeError`/`RangeError` now comes from the call site's frame: the backtrace lacks the native's
  frame. The arms already had that property for `:value`/`:float` entries and for `Rect.new`.
- mruby's `mrb_as_int` does not call `to_int` on arbitrary objects (it raises `TypeError`), so an object with a
  `to_int` takes no part; the check pins that, and would see a build whose `mrb_as_int` started calling it.
- The alias, computed-name installer and singleton worlds keep the gate; they were never sound for an Integer
  argument either (the arm called the native regardless), which the check records rather than fixes.
- Not done: core natives (ADR 0274's `NativeCoreDirect` guards) are a separate audit; specifiers other than
  `i f b o` stay unmodelled.
