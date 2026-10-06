# 0362. The comparison helpers mirror Comparable for String and Symbol and prove every other receiver a NoMethodError

Date: 2026-10-06

## Status

Accepted

## Context

ADR 0360 closed the by-name else of `bc2cpp_slow_div`, the one helper whose operator only Integer and Float answer.
Its table said what `<` `<=` `>` `>=` still need: `CallFacts::Answers#members` for them is Integer, Float,
Numeric, String, Symbol and Hash, because Comparable's body (what String, Symbol and Numeric reach) and `Hash#<`
(the subset tests, mruby-hash-ext) are Ruby in mruby's own mrblib, so the `definers` set has foreign Ruby
(`Comparable`, `Hash`) that ADR 0360's test rejects. The helpers (`bc2cpp_slow_lt`/`le`/`gt`/`ge`) keep a by-name
call for every receiver that is not a number.

## Decision

`CodeGen#numeric_slow_closed_cmp?(op)` holds when the world is closed (ADR 0360's gates, `BC2CPP_NUMERIC_SLOW_CLOSED=0`
is the kill switch) and:

* `definers(op)` has no engine Ruby, module or singleton definer, foreign definers only `Comparable` and `Hash`,
  native definers only Integer, Float and Numeric, and `members(op)` is inside `{Integer, Float, Numeric, String,
  Symbol, Hash}`. A user class that includes Comparable, defines the operator or subclasses Hash, String or Numeric
  adds a member, so that world keeps the by-name helper.
* The Ruby bodies the helper mirrors are the build's own: `CoreCompare` (`tools/bc2cpp/core_compare.rb`, modelled on
  `CoreMixins`, ADR 0261) compares `Comparable#<` ... `#>=` in `mrblib/compar.rb` by owner, file and normalized body
  (the message interpolation included), requires `Hash` to be the only other Ruby definer and `src/numeric.c` the
  only native one. `scripts/bc2cpp_numeric_slow_check.rb` fails when the real 3rd/mruby stops matching.
* `self <=> other` of a String, Symbol or other Numeric stays an Integer or nil answer: no engine or outside Ruby
  definition, prepend, unknown mixin or computed installer reaches `<=>` on String, Symbol, Numeric, Comparable,
  Object, Kernel or BasicObject (`core_native_arm_safe?`), and the String and Symbol registrations are exactly
  `mrb_str_cmp_m` and `sym_cmp`. A `<=>` on an unrelated class does not matter.

The closed helper then runs, by receiver:

| Receiver | Body |
| --- | --- |
| Integer, bigint, Float | `num_lt` & co.: `mrb_cmp`, `-2` raises `comparison of %t with %t failed` (unchanged) |
| String, Symbol, any other Numeric (`Numeric.new`: `num_lt` is registered on Integer and Float only) | Comparable's body: `mrb_cmp` is `String#<=>` for a String and dispatches `Symbol#<=>` for a Symbol; nil raises `ArgumentError` with `%T`, which is `"#{self.class}"` and `"#{other.class}"` exactly (same `to_s` dispatch), `num_lt`'s `%t` would print `nil` for NilClass |
| Hash | the method, by name |
| anything else | `bc2cpp_nomethod_named`, which dispatches by name first, so a wrong proof raises `closed-world proof violated` |

A build that defines `MRB_USE_COMPLEX` or `MRB_USE_RATIONAL` keeps the old by-name helper under `#if` (Rational
answers through Comparable, which the world scan of such a build lists but a libmruby linked later may add).

## Consequences

Soundness rests on the two lists above; the equivalence matrix in `scripts/bc2cpp_numeric_slow_check.rb` runs the
four helpers against the operator itself over Integer, bigint, Float (NaN, infinities, -0.0), nil, booleans,
String, Symbol, Hash, Array, Range, Numeric.new, Struct, Object and anonymous-class receivers with every operand,
comparing value, exception class and message, and the number of by-name calls (zero for a number, String, Symbol
or Numeric; one for the rest), at mrb_int 64, 32 (`MRB_INT32`) and without mruby-bigint. Class and module
receivers are left out of the matrix because the full-core test libmruby links mruby-class-ext (`Module#<`), which
the wio gem set the proof is made for does not.

**Hash is not closed.** `Hash#<` is Ruby over `Enumerable#all?`, `Hash#each` and `==` of the stored values; a
faithful mirror needs a by-name `==` per element (`mrb_equal` short-circuits identical objects, which differs for
NaN and a user `==`), so the by-name call for a Hash receiver stays and the helpers still count as holding one
(see the census figures in `docs/bc2cpp-dynamic-site-census.md`). Closing it needs either a compiled
`Hash#<` reachable from the helper's translation unit or a per-element `==` proof. Comparable includers with a user
`<=>` also keep the by-name helper; a direct call to the resolved `<=>` is the follow-up.
