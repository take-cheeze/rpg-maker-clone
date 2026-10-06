# 0361. The `+` and `*` helpers close their else by mirroring the Array and String bodies

Date: 2026-10-06

## Status

Accepted

## Context

ADR 0360 closed `bc2cpp_slow_div` because only Integer and Float answer `/`. It left `+ - *` open: the classes
that may answer them (`CallFacts::Answers#members`, wio closed world) are Integer, Float, Array and String, plus
Time for `+` and `-` (the host scan reads every core gem's sources, and wio does not link mruby-time), and the
Array and String bodies are `static` in mruby, so a direct class-tag switch needs a C++ equivalent of each.
`bc2cpp_slow_add_f` and `bc2cpp_slow_mul_f` have 712 and 442 generated callers, `bc2cpp_slow_sub_f` 471.

Every definition of `+` and `*` in the scanned native sources, counted by
`scripts/bc2cpp_numeric_slow_check.rb`: `array.c` 2 (`mrb_ary_plus`, `mrb_ary_times`), `string.c` 2
(`mrb_str_plus_m`, `mrb_str_times`), `numeric.c` 4 (`int_add`, `int_mul`, `flo_add`, `flo_mul`), `time.c` 1
(`time_plus`). `-` adds `ary_sub` (mruby-array-ext) and `time_minus`.

## Decision

`CodeGen#numeric_slow_closed?` now covers `+` and `*` (owners Integer, Float, Array, String) under the ADR 0360
conditions: closed world, no global refusal, singleton-free, no `method_missing` class, `definers` bounded with no
Ruby, module, foreign or singleton definer, and every member class an owner or a class whose whole lookup path is
known and runs through an owner (a user `class Foo < Array` without its own `+` runs `Array#+`). The helper is
then written twice, as for `/`: the old by-name text under `#if defined(MRB_USE_COMPLEX) || defined(MRB_USE_RATIONAL)`
and the closed text under `#else`. `BC2CPP_NUMERIC_SLOW_CLOSED=0` restores the old helper byte for byte. A user
class answering `+` leaves `+` open and `*` closed, and the reverse.

The closed text switches on the receiver's tag:

| Receiver | Arm | Equivalent of |
| --- | --- | --- |
| Fixnum pair | unchanged: the vm.c OP_MATH overflow arm | ADR 0292 |
| Integer, bigint, Float | `mrb_num_add` / `mrb_num_mul`, a non-numeric operand is its `TypeError` | `int_add`, `flo_add`, `int_mul`, `flo_mul` (they call it for the same tags) |
| String `+` | `mrb_str_plus(a, mrb_ensure_string_type(b))` | `mrb_str_plus_m` (`mrb_get_args "S"` is `mrb_ensure_string_type`, no `to_str`) |
| String `*` | `mrb_as_int`; `ArgumentError "negative argument"`; `mrb_int_mul_overflow` -> `ArgumentError "argument too big"`; `mrb_str_new(NULL, len)` filled by the method's doubling `memcpy`; the single-byte flag copied | `mrb_str_times` line for line |
| Array `+` | `mrb_ensure_array_type(b)`; overflow of the length sum -> `ArgumentError "array size too big"`; `mrb_ary_new_capa(sum)` then `mrb_ary_concat` of `a` and `b` | `mrb_ary_plus` (`ary_check_too_big` + `ary_new_capa` raise under the same condition as `mrb_ary_new_capa(sum)`) |
| Array `*` | `mrb_check_string_type(b)` -> `mrb_ary_join`; else `mrb_as_int`, negative -> `ArgumentError "negative argument"`, zero -> `mrb_ary_new`, length overflow -> `"array size too big"`, `mrb_ary_new_capa(len * times)` and `times` `mrb_ary_concat` calls | `mrb_ary_times` (`ARY_MAX_SIZE / times < len` is the overflow test, the capacity check is `ary_new_capa`'s) |
| anything else | `bc2cpp_nomethod_named`, which dispatches by name first, so a wrong proof raises `closed-world proof violated` | |

Time. The Time arms cannot be mirrored (`struct mrb_time` and `time_plus` are private to mruby-time). The host scan
lists Time as a `+` definer, so the closed form removes it only when `mruby-time` is not in the build's gem list
(`BC2CPP_BUILD_GEMS`, now handed to `CodeGen.build_gem_names`) and no declared class has Time among its ancestors;
a build that links mruby-time keeps `+` by name and `*` closed. The gem list is the build's own, dependencies
included (`bc2cpp_closed_world_env`), so a gem pulling mruby-time in re-opens `+`.

`-` stays open. `Array#-` (mruby-array-ext, linked by wio) is a hash set or an `==` walk over the operands calling
user `hash` and `==`, with no public entry point; mirroring it would copy `ary_subtract_internal`. `bc2cpp_slow_sub_f`
is unchanged.

Soundness:

* Same as ADR 0360 for the else: `members` bounds the receiver classes and `bc2cpp_nomethod` is the proven-dead arm.
* The arms are only as good as the mruby tree they mirror. `scripts/bc2cpp_numeric_slow_check.rb` pins a digest of
  each mirrored body (`mrb_ary_plus`, `mrb_ary_times`, `mrb_str_plus_m`, `mrb_str_times`, `int_add`, `int_mul`,
  `flo_add`, `flo_mul`, `mrb_num_add`, `mrb_num_mul`) and counts the native `+`/`*` definitions (a second definer of
  `String#+` in some gem's C would not change `members`), so an mruby bump that edits one fails the check until the
  mirror is re-derived.
* A libmruby that links Complex or Rational keeps the old text; `-DMRB_USE_COMPLEX -DMRB_USE_RATIONAL` is
  compiled and run by the check too.
* `[] * n` with a huge `n` loops `n` times in mruby and not in the mirror (it returns the empty result at once).

## Consequences

Measured with `scripts/bc2cpp_dynamic_site_census.rb` on the wio closed world (shipped pass), master `9361f234`.
The census now skips the `#if defined(MRB_USE_COMPLEX)` by-name copy of a helper written twice (wio never defines
them), which ADR 0360's numbers still counted textually:

| | Before | After |
| --- | ---: | ---: |
| by-name `bc2cpp_send` calls held in helpers | 23 | 21 |
| generated callers of a helper that still holds a by-name call | 5,509 | 4,355 |
| `bc2cpp_send` call sites in generated bodies | 2,321 | 2,321 |
| sites that can reach by-name dispatch (bodies + helper callers + 417 block + 30 funcall sites) | 8,277 | 7,123 (-13.9%) |

Equivalence is `scripts/bc2cpp_numeric_slow_check.rb`: the closed helper against the real method for every pair of
about 60 values (Fixnum and heap Integer edges, bigints, Float mixes, NaN and infinities, empty, frozen, UTF-8 and
subclass String and Array, a 131072-element Array, Hash, Range, Class, an object answering every implicit
conversion, a user class with no operator), error class and message, result class and frozen-ness, on mrb_int 64,
int32 and no-bigint builds, called directly and through the compiled method against the interpreter.
The matrix is 9,296 helper-versus-method cases and 9,398 interpreter-versus-compiled answers on mrb_int 64 and int32,
6,897 and 6,900 without mruby-bigint (a String count past 1000 is skipped there: IM is not mrb_int's maximum and the
interpreter would allocate it), each with 0 mismatches, once more with `-DMRB_USE_COMPLEX -DMRB_USE_RATIONAL` (the
by-name copies). Of seven hand-made mutants of the mirrors (an error message, a dropped type check, a wrong zero
case, a wrong operand, one repeat too few) six fail the check; copying the single-byte flag in `String#*` is a length
cache hint with no observable effect, and its mutant survives.

`-` (471 callers) and the other helpers listed in ADR 0360 remain open.
