# 0290. bc2cpp: the else of a guarded numeric arm is a typed helper, not a by-name send

Date: 2026-10-01

## Status

Accepted

## Context

A guarded numeric arm inlines the Fixnum case and used to send everything else by name:
`bc2cpp_send(M, a, :+, 1, b)` at every site. The arms are FIXNUM_ARITHMETIC (`+ - *`),
FIXNUM_COMPARE (`< <= > >=`), FLOAT_DIV_RECEIVER (`/`), INTEGER_LSHIFT (`<<`), FIXNUM_SHIFT
(`>>`), FIXNUM_BINARY (`% & | ^`) and INTEGER_UNARY (`-@ zero? round`): 3,409 sites in the wio
closed world, of the 10,181 cached dispatch sites. What reaches those else arms is not
arbitrary. The inline tiers already take two Fixnums (and the compare/arithmetic opcodes take
the Integer/Float pairs ahead of them), so what is left is a bigint operand, a heap Integer, a
Float against a bigint, an operand the tier does not own (nil, String, Array, a user class),
and the overflow of a shift. For the numeric ones the method the send finds is a C function in
libmruby (`mrb_int_add`, `mrb_bint_div`, `int_mod`, `cmpnum`, ...): the call went through
`mrb_funcall`, a method lookup and a frame to reach a function the generated code can call.
ADR 0276 already did this where NumericFlow proves the operands (`bc2cpp_num_div`,
`bc2cpp_num_cmp`, `mrb_num_add`); the 3,409 sites are the ones it cannot prove.

## Decision

**One typed helper per operator** (`bc2cpp_slow_add`, `_lt`, `_div`, `_mod`, `_and`, `_lshift`,
`_neg`, ...; tools/bc2cpp/codegen_numeric_slow.rb) replaces the send at the else of each arm. It
switches on the operand tags and runs the function the method reaches, and sends by name only
for an operand class it does not own. The by-name call is therefore written once per helper
(17 helpers, 20 by-name calls, in the whole program) instead of once per site (3,409), and the helper is emitted, ahead
of the compiled functions and behind the symbol cache, only when a site calls it.

- `+ - *`: two Integers are vm.c OP_MATH (`mrb_int_*_overflow`, then `mrb_int_value` or
  `mrb_bint_*_ii`); any other Integer/bigint receiver with an Integer/bigint/Float operand is
  `mrb_num_add/sub/mul`, which is Integer#op's body; a Float receiver with those operands is
  `mrb_num_*` too (Float#op's body, Complex excluded). The Float receiver is admitted only when
  Float has no Ruby definition of the operator either (`_f` variant); a Ruby redefinition of the
  operator on Integer/Numeric keeps the old by-name arm.
- `< <= > >=`: `mrb_cmp` (the `cmpnum` of Numeric#<) for an Integer/bigint/Float receiver and
  its ArgumentError for an incomparable operand, so a bigint against NaN answers what the
  method answers.
- `/`: `int_div`'s body (`mrb_div_int_value`, `mrb_bint_div`, the Float division); `%`, `& | ^`:
  `int_mod`/`int_and`/... for two Integers; `<< >>`: `int_lshift`/`int_rshift` for an Integer
  count (`mrb_num_shift`, then `mrb_bint_lshift/rshift`); `-@`: Numeric#-@ is `0 - self`, so
  the OP_SUB form for an Integer (overflow into `mrb_bint_sub_ii`), `mrb_num_sub` for a bigint
  and the inline `0 - float` for a Float (`-(0.0)` stays `0.0`); `zero?` of a Float; `round` of
  a bigint (self).
- Left on the by-name call because the exact body is not reachable from outside libmruby or the
  exception must be the method's own: a zero divisor, `MRB_INT_MIN` or a Float/bigint as a shift
  count, `Float#%` and `Integer % Float` (`flodivmod` is static), `Float#round`, `bigint.zero?`
  (Numeric#zero? runs Integer#==, which has no entry point outside libmruby), a Complex operand.

**Soundness**. The gates are the arms' own (`native_only_mono?` for the compare/binary names,
`builtin_class_send_safe?` for `+ - * / << >>`, `integer_ancestry_native?` for the unary
names); the helper adds none, and the Float receiver adds its own. Without mruby-bigint the
`#ifdef MRB_USE_BIGINT` arms vanish and the same cases take the by-name call (an Integer
overflow raises the VM's own "integer overflow"). A bigint is never read as an `mrb_int`: every
`mrb_integer()` follows an `mrb_integer_p()` test, so the 32-bit `mrb_int` targets, where
anything past 31 bits is a heap Integer and past `0x7fff_ffff` a bigint, cannot hit the
`RangeError` a bigint handed to an `mrb_int` parameter raises. No constant of the helpers is
computed by a shift or an OR (AGENTS.md: mrbc folds those into an unloadable irep entry).

**GC**. The compiled frame's C++ locals are not roots (ADR 0272). A helper keeps a heap result
alive the way a send does: it saves the arena on entry, restores it after the operation (the
temporaries - `mrb_bint_new_int`, a boxed Float for `mrb_as_float` - are dropped) and
`mrb_gc_protect`s the result, so one slow-path call leaves at most one arena entry, where the
direct `mrb_num_add` of the old arm left every temporary until the frame returned. The
Fixnum tier's inline `mrb_num_*` on overflow (ADR 0279) is unchanged.

## Consequences

- Sends in the shipped wio build: 10,181 cached sites before, 6,651 after; the 3,409 arms
  have no by-name call of their own (they were `FIXNUM_ARITHMETIC` 1,704, `FIXNUM_COMPARE` 919,
  `FLOAT_DIV_RECEIVER` 297 and 489 of the other four tags). The by-name calls that remain are
  the operand classes the helpers do not own: the dispatch is moved, not removed, for a
  String#+ or an Array#&. What changes for numbers is that a bigint operand, a Float against a
  bigint and a bigint compare/shift/modulo now call the C function directly, with no lookup
  and no method frame, and with an exact (not accumulating) arena footprint.
- Behaviour. `scripts/bc2cpp_numeric_slow_check.rb` runs 22,005 operator/operand answers
  (Fixnum and mrb_int edges, heap Integers, bigints, Float -0.0/NaN/Infinity, nil, String,
  Array, user classes, negative and oversized shift counts, floor division and modulo signs)
  through compiled and interpreted mruby and requires identical values, Integer#hash
  (representation), exception class and message, on a 64-bit build, a 32-bit-`mrb_int` build
  (`-DMRB_32BIT -DMRB_INT32`) and a build without mruby-bigint; it also requires that a numeric
  operand pair makes no by-name call, that a bigint operation leaves at most one arena entry,
  and that a loop of bigint arithmetic with `GC.start` survives. It pins the negative cases
  (Integer#+ / Float#- / Integer#< redefined in Ruby keep the by-name arm). The 32-bit run
  found that Integer#+ with an `MRB_INT_MIN` operand is wrong in the 32-bit bigint core
  (`mrb_bint_add_n` negates the operand): the arm used to call it, the OP_MATH form used now
  does not.
- Not covered: CI does not run a 32-bit-`mrb_int` or a no-bigint libmruby, as for ADR 0279 and
  0287, so those halves are local checks (`BC2CPP_MRUBY_FULL32`, `BC2CPP_MRBC32`,
  `BC2CPP_MRUBY_NOBIGINT`); the 32-bit build is the 64-bit host with the targets' defines, so
  it has their arithmetic but not their pointer width. Sites whose operands NumericFlow proves
  (ADR 0276) never had an else and are unchanged; the families NumericFlow does not model
  (`% & | ^ << >>`) get no proven-operand variant, so a site with Integer-only operands still
  carries the helper's tag test.
