# 0291. bc2cpp calls String#size and #length directly behind an exact-String arm

Date: 2026-09-30

## Status

Accepted

## Context

The request was to replace the by-name sends of the common container methods
(`[]`, `[]=`, `size`, `empty?`, `length`, `push`, `include?`, `first`, `delete`,
`keys`, `key?`, `pop`, `index`, `max`, `min`) with direct C calls behind a
class switch, because a whole-program count of the wio closed world found about
2,000 `bc2cpp_send` sites for them.

Classifying those sites by the code that precedes each send showed the count is
the number of *else arms*, not of unguarded dispatches. Of the 1,903 sends to those
names, 1,807 are the `else` of an exact-class switch, 83 (`max`, `min`) are the
fallback after an inline numeric loop, and 13 sit outside any arm (`delete` 4,
`index` 3, `push` 2, `first` 2, and the generic `[]`/`[]=` helpers' last resort):

- `[]`/`[]=` (889): the GETIDX/SETIDX exact Array/Hash/String arms
  (`bc2cpp_getidx`, ADR 0216) and their per-site inline copies;
- `size`, `length`, `empty?`, `first`, `pop`, `key?`, `keys` (716): the arms
  `NativeExpressionDevirt` generates from the registered natives (Array, Hash,
  and String for `empty?`);
- `push` (95): ARRAY_PUSH;
- `index` (37): NATIVE_CORE_DIRECT (ADR 0257);
- `include?` (53): Array#include? is compiled from mrblib (TYPED) and
  Hash#include? is a generated arm;
- `delete` (30): the else of a POLY chain over the LCF classes, whose other
  receivers are a Hash or an Array.

None of those names has a receiver set the existing machinery could not already
reach, except one. The container method with a receiver class in the set and no
arm at all is **String#size / #length**: the generated Array/Hash arms were
emitted for 358 sites and a String fell to the send. It was left out on purpose
(ADR 0165): `mrb_str_size` reads `RSTRING_CHAR_LEN`, a macro private to `string.c`
whose meaning follows `MRB_UTF8_STRING`.

Methods that cannot be matched exactly stay sends: `Array#include?` (Enumerable
in Ruby, whose `==` argument order and NaN behaviour differ from `mrb_equal`),
`Array#delete` and `#delete_at` (static, read their arguments with
`mrb_get_args`), `Hash#delete` (Ruby), `first(n)`/`pop`/`shift(n)` (argument
counts read from the caller's frame), `max`/`min` with a block or a
non-numeric element (Enumerable in Ruby).

## Decision

Add String#size and String#length as two audited rows of
`NativeCoreDirect::ENTRIES`. Both are `mrb_str_size`, so the row is pinned by
that function's exact body, the one-registration check of ADR 0257, and a new
`:source` check that the non-UTF-8 definition of the macro
(`#else #define RSTRING_CHAR_LEN(s) RSTRING_LEN(s)`) is still in `string.c`.

The C side is a `static inline` helper per name, emitted once. It is
`mrb_int_value(M, RSTRING_LEN(str))` when `MRB_UTF8_STRING` is not defined, which is
this project's build (no bignum on a 32-bit `mrb_int`: the length is a length).
Under `MRB_UTF8_STRING` the helper is a `mrb_funcall` of the same name, so the arm
can never disagree with a UTF-8 build; it simply stops being a saving there.

The arm is the existing exact-class guard (`mrb_string_p(r) && class ==
M->string_class`), so a subclass, a singleton and a frozen-or-not String with
an override dispatch as before. The soundness gate is `native_core_entry_safe?`:
closed world only, no project `String#size`, no prepend or unresolved mixin on
String, no dynamic installer, and no outside Ruby definition, alias, `undef` or
computed definition on String (`ClosedWorld#core_native_arm_safe?`). `size` and
`length` are gated separately.

The registered-expression chains (`compile_native_registered_expression`) now
send their last arm through the same wrapper (`registered_expression_fallback`),
so the String arm follows the generated Array and Hash arms. The wrapper also
drops an entry whose owner cannot be the receiver when an unguarded exact-literal
proof (ADR 0280) names another builtin.

## Consequences

- 277 of the 358 `size`/`length` sites in the wio closed world gain a String
  arm; the generated C++ grows by 56 KB (0.25%). The send stays as each arm's
  else, so no send site is removed; executed dispatches for String receivers are.
- The remaining container sends are else arms of switches that already exist.
  A further slice would have to be a new *kind* of arm (Range keys for
  `Array#[]`, `Array#delete`, `String#+`), not a wider class switch.
- `scripts/bc2cpp_native_core_direct_check.rb` covers the audit (including
  mutations of the macro, the body and the aspec), every withdrawal reason, and a
  compiled-versus-interpreter comparison on Strings (empty, multibyte, binary,
  subclass, frozen, 300 bytes, singleton `size`) and non-String receivers.
- Residual risk: the UTF-8 branch of the helper is a send and is not executed by
  any check (no UTF-8 build exists here); the byte-length branch was run against a
  64-bit `mrb_int` mruby only. It does no arithmetic on the length, so no 32-bit
  difference is expected, but no 32-bit build was run.
