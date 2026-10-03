# 0324. bc2cpp: INTEGER_CONSTANT_PROOF sees native constant definitions and a jump onto a SETCONST

Date: 2026-10-03

## Status

Accepted

## Context

ADR 0318's author found two latent holes in `IntegerConstants` (`tools/bc2cpp/integer_constants.rb`), the proof behind
`@integer_constants` (Fixnum operands, return facts, argument pools, embedded `:fixnum` ivars, inlined constant
values), and left them because fixing them changes generated code. Both make the proof wrong, not merely weak: a bare
constant name is admitted as an Integer, and every consumer then omits the tag test.

1. `native_const_names` scanned `mrb_define_const(` with a lazy `.{0,200}?` window. A lazy quantifier at the end of a
   pattern matches zero characters, so the scan returned no name at all and poison source 3 ("a native
   `mrb_define_const` / `mrb_define_global_const` / `mrb_define_const_id`") never fired. A name defined natively as a
   Float, nil or String and also assigned an Integer by Ruby elsewhere was an Integer constant.
2. `const_source_kind` had no guard for a `SETCONST` that a conditional jump lands on. `X = c || 1` compiles to
   `GETCONST c; JMPIF L; LOADI 1; L: SETCONST X`: the nearest writer is the `LOADI`, but on the other path the register
   holds `c`. `X = c && 1` likewise binds `c` (nil, false, a Float) on the short-circuit path. `IntegerConstantRanges`
   already withdrew these (ADR 0318).

### Reproductions (compiled against interpreted, `scripts/bc2cpp_integer_constants_check.rb`, master `7818f0f5`)

A Float constant defined natively (`mrb_define_const(M, c, "NATF", mrb_float_value(M, 2.5))`) while `IcOther::NATF = 1`
exists in Ruby, then `IcNat::NATF + 1`: interpreted 3.5, compiled `-4607182418800017406` (the Float's bits read as an
mrb_int). The same with a nil constant (`nil + 1`: interpreted NoMethodError, compiled `1`), a String (`"s" + 1`:
TypeError against `47138748609353`), and `ORC = FLTV || 1` (`ORC + 1`: 3.5 against the garbage), `ANDN = NILV && 1`
(`1` against NoMethodError), `ANDF = (FLTV > 9) && 1` (`3` against NoMethodError). Full-core and core-only builds both
differ; after the fix both agree, on the 64-bit builds and on the 32-bit `mrb_int` build.

## Decision

* `IntegerConstants.analyze` poisons with `native_defined_const_names` (the scan `KEYWORD_NEVER_DEFINED_CONST_RECEIVER_SUPPORT`
  and `IntegerConstantRanges` already used: `mrb_define_*const*`, `mrb_const_set`, `mrb_define_class`/`module`, each over
  a bounded `[^;]{0,200}` window, quoted names and `MRB_SYM*`). `native_const_names` is gone: it was a subset of that
  scan, and its only effect was to be wrong.
* A `SETCONST`/`SETMCNST` that a jump or a catch handler lands on is an unclassified (poison) definition, as in
  `IntegerConstantRanges.analyze`. The arithmetic forms were already refused: the walk's barrier stops at an `ADD`
  or `MOVE` sitting on a jump target.
* No kill switch: this is a soundness fix. A name that is poisoned only costs a proof.

## Consequences

Shipped wio/rpg2k output (`scripts/bc2cpp_coverage_report.rb`, shipped pass, `3rd/*` populated, master against the
fix): **not byte-identical, by one real finding.** With digit-masked lines (symbol indices are renumbered) the diff is
28 lines: the symbol table gains `Variables`, `MAX`, `MIN`, and two constant reads that were inlined as `999999` and
`-999999` become `GETCONST` lookups. The census counts are equal: `bc2cpp_send` 2,538, `bc2cpp_slow_*` 3,343,
`bc2cpp_getidx` 2,066, `mrb_fixnum_p(` 3,597, `bc2cpp_nomethod` 4,386. The diagnostic loses `CONST MAX`/`MIN`
(693 -> 691 Integer constants, 470 -> 468 with a value) and `Game::Variables#@max`/`@min` stop being embedded
`:fixnum` (they are `:value`).

The cause is an engine name collision, and the old proof was wrong for it: `MAX`/`MIN` are assigned an Integer in
`mruby-rpg2k/mrblib/game.rb:1504-1505` (`Game::Variables::MAX`/`MIN`) and defined natively as Floats at
`3rd/mruby/mrbgems/mruby-numeric-ext/src/numeric_ext.c:511,514` (`Float::MIN`/`MAX`), and the proof keys on the bare
name. Behaviour did not differ in the shipped game: the only engine reads (`game.rb:1521-1522`, `@max = rpg2003 ?
RPG2003_MAX : MAX`) resolve lexically to `Game::Variables::MAX`, and no engine code reads `Float::MAX`/`MIN`. The cost
of the fix is the lost inlining of those two reads and the two embedded ivars (the clamp in `Game::Variables#[]=`
compares against a boxed value again). Nothing else in the engine changes. Restoring them soundly is an engine rename of
the two reads to a unique name (`RPG2000_MAX = 999_999` read by `initialize`, `MAX` kept as the public alias); not done
here, so the PR changes only the generator.

Soundness limits that remain: a native constant whose name is not a string literal or `MRB_SYM` (a table or a variable
in the call) is invisible to the scan. `@dynamic_constant_mutation` (ADR 0318) covers the computed-name `mrb_const_set`
for `IntegerConstantRanges` consumers; `IntegerConstants` consumers do not consult it. In the 82 scanned native sources
the only such calls are mruby's own implementations (`mrb_const_set`/`mrb_define_const*` bodies in `variable.c`, the
`OP_SETCONST`/`OP_SETMCNST` handlers in `vm.c`, `class.c`'s class binding) and `Random` in `mruby-random`; the engine's
own `mrb_const_set` names are lowercase `_zobjs`/`_game_start` literals.

## Tests

`scripts/bc2cpp_integer_constants_check.rb`: unit cases (the scan reads each native form, including a call split over
several lines, `mrb_define_const_id(MRB_SYM)`, `mrb_define_global_const`, `mrb_const_set`; the admitted set keeps the
sound constants `PLAIN`, `SUM = PLAIN + 1`, `IFY = 100 if cond` and withdraws `ORC`, `ORM` (scoped), `ANDN`, `ANDF`,
the five native names, a ternary with a Float arm and `1 + (c || 2)`), the diagnostic's constant list, and the fixture on
real mruby compiled against interpreted (values and exceptions, with pinned results on the full-core build; a core-only
mruby raises the base class, so there the interpreter's own line is the pin). It fails on master (49 failing checks across the 64-bit, core-only and 32-bit builds) and passes
after. `scripts/bc2cpp_integer_constants_mutation_check.rb`: an unmutated control and eight mutants (no native poison,
a window of 20 characters, the lazy window, no `mrb_define_global_const`, no quoted name, no `MRB_SYM` name, no
`mrb_const_set`, no jump-onto-SETCONST guard), each killed; the copy lives inside the repository so the closed world is
not empty. New `integer-constants` shard in `bc2cpp-checks`; the 32-bit run is in `bc2cpp-width (int32)`. One mutant was
dropped as equivalent: dropping the guard for `SETMCNST` alone changes nothing because the scoped assignment always
routes its value through a `MOVE` on the jump target, which the walk's barrier already refuses.
