# 0182. Generate Array#first and #last's zero-argument path from mruby core C

Date: 2026-09-21

## Status

Accepted

## Context

mruby's core `Array#first` and `Array#last` accept an optional count. Their C
wrappers (`mrb_ary_first`, `mrb_ary_last`) begin with a self-contained
`mrb_get_argc(mrb) == 0` branch that returns the first or last element, or
`nil` for an empty receiver; a count follows separate subsequence logic.
bc2cpp had a hand-written `first` fast path, while `last` used ordinary
dynamic dispatch, and neither was derived from the C source.

## Decision

Recognize only that zero-argument branch in `mrb_ary_first` and
`mrb_ary_last`. Its condition and index expression are run through the
existing expression allowlist (`ARY_LEN`, `mrb_ary_ptr`, integer arithmetic),
so an unexpected body shape produces no expression. Emit
`(cond) ? (ARY_PTR(mrb_ary_ptr(recv))[index]) : (mrb_nil_value())` behind the
same exact-Array class guard as the other C-derived paths. Register the two
names with a zero-argument arity only; call sites that pass a count keep
dynamic dispatch. Range's own `first`/`last` registrations
(`mrb_range_beg`/`mrb_range_end`) share the generated switch.

## Consequences

`Array#last` gains a native path, and `Array#first` is now derived from mruby
source instead of a hand-maintained copy. Subclasses, singleton classes and
Ruby overrides use normal dispatch. This is a static code-generation change;
no runtime speedup has been measured.
