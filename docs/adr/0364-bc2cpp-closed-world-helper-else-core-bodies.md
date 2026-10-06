# 0364. The `^`, `>>` and `round` helpers mirror their core classes' bodies and drop the by-name else

Date: 2026-10-06

## Status

Accepted

## Context

ADR 0360 closed the else of `bc2cpp_slow_div` because only Integer and Float answer `/` and the helper already ran
both bodies. It listed the other helper names and what each lacked: operand coercion (`>>`, `round`, `^`), static
mruby bodies (`% & | << -@`) or no bounded member set (`zero?`, `===`). This ADR takes the helpers whose missing
piece can be generated inside the helper from public mruby API: the core class's body is mirrored line by line for
the receiver classes `CallFacts::Answers#members` names, and every other receiver is a proven NoMethodError.

`members` for the wio closed world (all three compiled gems, `SKIP_UNSUPPORTED=1`; `definers` printed alongside):

| Name | Classes that may answer | Definers | Closed here |
| --- | --- | --- | --- |
| `^` | Integer, NilClass, TrueClass, FalseClass | native only (numeric.c, object.c) | yes |
| `>>` | Integer | native only (numeric.c) | yes |
| `round` | Integer, Float | native only (numeric.c) | yes |
| `&` `\|` | Integer, NilClass, TrueClass, FalseClass, Array | native only | no |
| `<<` | Array, String, IO, Integer, `Enumerator::Yielder`, `RGSS::ErrorReport::Tee` | native, Ruby (Tee), foreign Ruby (Yielder) | no |
| `%` | Integer, Float, String | native, foreign Ruby (`String#%` in mruby-sprintf) | no |
| `-@` | Integer, Float, Numeric, String | native (`String#-@`), foreign Ruby (`Numeric#-@`) | no |
| `zero?` | none: unbounded | native owner unreadable, foreign Ruby `Numeric#zero?` | no |
| `===` | none: unbounded | `Kernel#===` answers every object | no |

## Decision

`numeric_slow_closed?(name)` (ADR 0360) now also holds for `^`, `>>` and `round` with the owner sets above. The
conditions are unchanged: a closed world with no global refusal, `exact_instances_singleton_free?`, no
`method_missing` class, `Answers#definers(name)` bounded with no Ruby, module, foreign Ruby or singleton definer,
and `members(name)` a subset of the owners. `numeric_slow_source` then emits the closed body behind the same
`#if defined(MRB_USE_COMPLEX) || defined(MRB_USE_RATIONAL)` pair as `/` (the old by-name helper stays in the
`#if` arm: Rational and Complex define `round` and answer more receivers than the scan lists), and
`BC2CPP_NUMERIC_SLOW_CLOSED=0` keeps the old helper byte for byte. A user class defining the operator makes the
set not a subset (the helper stays open); for `^` and `round` it also takes the site off the helper.

The mirrored bodies:

* `^`: an Integer or bigint receiver is `int_xor` with no operand check: the operand is read by
  `mrb_integer(b)` (or `mrb_bint_xor(mrb_as_bint(a), b)` for a bigint operand) exactly as the method reads it,
  so a Float or heap operand gets the method's own misread. nil and false are `false_xor` (`mrb_test(b)`), true is
  `true_xor` (`!mrb_test(b)`); the C bodies take their argument as `"b"`, which is `mrb_test`.
* `>>`: `int_rshift`: `mrb_as_int` coerces the count first (a String, nil or Array count raises the method's
  `TypeError`, a Float is truncated), `0` returns the receiver, `MRB_INT_MIN` raises `integer overflow in bit
  shift`, a bigint receiver goes to `mrb_bint_rshift`, an Integer to `mrb_num_shift` with the width negated, and a
  left shift that overflows to `mrb_bint_rshift(mrb_bint_new_int(...))` (RangeError `integer overflow in bit
  shift` without bigint).
* `round`: Integer and bigint return `self` (`int_round` with no digits); a Float is `flo_round` with
  `ndigits == 0`: FloatDomainError for Infinity/NaN, the hand-written round-half-away, `FIXABLE_FLOAT` selecting
  a Float or an Integer result. `mrb_check_num_exact` is not exported, so its two raises are spelled out.

Receivers outside the owner set take `bc2cpp_nomethod_named`, which dispatches by name before it raises, so a
wrong proof surfaces as `closed-world proof violated` (ADR 0262, 0275) instead of running the wrong code. All three
bodies live in core mruby (`numeric.c`, `object.c`), which every build links, so no gem-presence assumption is
needed.

Not closed, and why:

* `&` `|`: the Array receiver runs `ary_and`/`ary_union` of mruby-array-ext, which build a khash set (`kh_*`,
  `mrb_equal`, a shared-copy dance) that is static and not reproducible from public API.
* `<<`: `String#<<` is `str_concat0` (codepoints, binary flag, frozen check), `IO#<<` is `io_lshift` over
  `fd_write`, both static; `Tee#<<` is compiled Ruby of another gem and `Yielder#<<` is foreign Ruby.
* `%`: `String#%` is Ruby (`args.is_a?(Array) ? sprintf(self, *args) : sprintf(self, args)`), so a mirror would
  call `is_a?` and `sprintf` by name or assume they are not redefined, and `definers` of both are unbounded
  (`Kernel`). Integer and Float alone would need `flodivmod` (static).
* `-@`: `String#-@` is `str_uminus` of mruby-string-ext. The member scan covers every core gem's natives, not the
  gems a build links, so the String arm cannot be proven present; and `Numeric#-@` is foreign Ruby `0 - self`.
* `zero?`: `Numeric#zero?` (mruby-numeric-ext) is Ruby `self == 0`, a by-name call by definition, and a native
  `zero?` owner (`FileTest`) the scan cannot read makes `definers` nil.
* `===`: `Kernel#===` answers every object; `members` is nil.

## Consequences

Measured with `scripts/bc2cpp_dynamic_site_census.rb` on the wio closed world (shipped pass, base `9361f234`).
The census scans text, so the `#if` arm kept for Complex/Rational builds is stripped from both runs (as ADR 0360
counted `/`):

| | Before | After |
| --- | ---: | ---: |
| by-name calls held in helpers | 23 | 19 |
| generated callers of a helper that still holds a by-name call | 5,509 | 5,483 |
| `bc2cpp_send` in generated bodies | 2,321 | 2,321 |

The four removals are `^` (4 callers), `>>` (17, two calls) and `round` (5). A build that links Complex or Rational
is unchanged.

`scripts/bc2cpp_numeric_slow_check.rb` runs each closed helper directly against the real method over every member
class pair: Fixnum, heap Integer, bigint, negative and oversized shift counts, `MRB_INT_MIN`, Float (NaN, +-Infinity,
-0.0, 1.0e19), nil, true, false, String (frozen and not), Symbol, Array, Hash, Range, a user object, a class, a bare
`Numeric`; value, Float bits, `Integer#hash`, exception class and message must agree, compiled and interpreted. It
runs at `mrb_int` 64, 32 (`BC2CPP_MRUBY_FULL32`) and without bigint (`BC2CPP_MRUBY_NOBIGINT`), and shows the
open helpers (a user `>>`) and the Complex/Rational arm unchanged. The interpreted-versus-compiled comparison
leaves out an Integer receiver with a heap operand for `^`: the method reads the operand's address as an integer,
which differs between the two runs, so the direct comparison (same object) covers those pairs.
