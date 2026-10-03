# 0318. bc2cpp: constants with a proven Fixnum interval, and native `:int` arguments that need no tag test (NUMERIC_CONSTANT_RANGES, NATIVE_INT_ARGS)

Date: 2026-10-03

## Status

Accepted

## Context

ADR 0313 measured the 115 `Bitmap.new(w, h)` sites of the rpg2k engine that keep an `mrb_integer_p` test and, as its else,
the by-name `new` send, and found their `w`/`h` are not constructor arguments but numeric constants (`LINE_H`,
`SCREEN_W`, `TILE`, `FACE_SIZE`: `flowfail`), native `.width` results, `Array#max` and `Window#width`. This ADR measures
that claim again leaf by leaf, and builds the part of it that is provable.

### Measurement (wio closed world, master `cd86085f`, `3rd/*` populated, read-only probe `BC2CPP_NATIVE_INT_ARGS=<file>`)

Every native-direct call site whose `:int` argument keeps `mrb_integer_p` and a by-name else is probed with the Fixnum
proof (`proven_fixnum_operand?`); a failing argument is classified by the register's writer and the leaves behind it
(`numeric_root_leaves`). `shipped.cxx` is byte-identical with the probe on.

The sites: 115 `Bitmap.new`, 64 `Sprite#x=`-style exact calls (`NATIVE_EXACT_DIRECT`), 78 guarded arms. Only the first
two remove a send when their tag test goes; an arm keeps its class test's else whatever its arguments are.

First failing leaf of the 155 failing `Bitmap.new` argument positions (230 positions, 75 already proven by the Fixnum
proof; **the construct site never asked the proof**, `arg_checks` was unconditional):

| first failing leaf | positions |
| --- | ---: |
| arithmetic (`SUB`, `MUL`) of Fixnum constants and literals only (`SCREEN_W - 2 * BORDER`, `HEADER_H * 3`) | 39 |
| arithmetic with a non-constant leaf (`Array#size`/`max`, a parameter, `Window#width`, an element) | 60 |
| a String or `true` argument (the file-load form `Bitmap.new("Title/#{name}", true)`, 17 sites: the test is always false) | 33 |
| `Array#max` result used directly | 6 |
| a parameter | 5 |
| `Bitmap#width`/`height` result | 6 |
| a constant read directly (`ANIM_CELL`, `SCREEN_W`, `SCREEN_H`, `BATTLE_STATUS_W`) | 5 |
| other | 1 |

Constants. `LINE_H`, `SCREEN_W`, `TILE` and `FACE_SIZE` are already `INTEGER_CONSTANT_PROOF` names (693 names, 470 with
an exact value); what `flowfail` says is only that `NumericFlow` does not model a class body (its `DEF`, `TCLASS`,
`CLASS` and `EXEC` instructions are outside `SUPPORTED_OPS`, so the `NumericConstGroup` of every constant defined in a
class body fails, structural or not). The Fixnum proof never reads that group. The constants that really are not Fixnum
constants are the ones defined by `MUL` or `DIV`, which `IntegerConstants` does not classify: `HEADER_H = LINE_H +
Window::BORDER * 2`, `COLS = SCREEN_W / TILE + 1`, `VISIBLE_SLOTS`, `ROWS`. Why the rest fail: 157 names have a
definition that is not an Integer expression (Arrays, Strings, Floats, `2**32` masks), 18 alias themselves
(`Scene::Map::TILE = Game::TILE`, an alias of its own bare name, which a least fixpoint never resolves), 15 are
defined by a foreign Ruby or native source, 4 by both. Reopened modules are not the cause (the names are keyed by bare
name, so a reopening adds a definition), nor `freeze`, nor class-body order. The `Game::Map`/`RPG2k::Scene::Map` cref
issue of ADR 0313 does not apply to constants: keyed by bare name, every definition counts.

Sites that become proven if one class alone is proven (Bitmap.new, same tree):

| proven | sites without a tag test |
| --- | ---: |
| nothing (master) | 0 |
| the existing Fixnum proof asked at the construct site | 29 |
| plus Fixnum constants and `+ - * /` of intervals (this ADR) | 65 |
| plus `Array#size`/`length` (`size * LINE_H`) as a fixnum of unknown range | not provable: the product overflows the narrowest Fixnum |
| plus `Array#max`, `Window#width`, `Bitmap#width` readers | at most 11 of the remaining 50 |

The remaining 50: 17 file-load form sites (a String/`true` argument: always false), 11 `Array#size`/`max`/`length`, 8
user readers (`left_panel_w`, `screen_width`, `digits`), 4 `width`/`height`, 4 parameters, 6 others (a protected
range, a depth limit, a captured local, a join).

## Decision

### NUMERIC_CONSTANT_RANGES (`integer_constant_ranges.rb`)

`IntegerConstantRanges.analyze` computes for every bare constant name an interval, with IntegerConstants' soundness
argument (keyed by bare name; a name is admitted only when every definition is visible) and its four poison sources,
plus the names a native `mrb_const_set`/`mrb_define_*` spells (`native_defined_const_names`; `native_const_names`
misses them, see below). A definition is `[:literal, v]`, an alias of another bare name, or `ADD`/`SUB`/`MUL`/`DIV`/
`ADDI`/`SUBI` of those. A name is known when all its definitions are; its interval is the hull of theirs; an alias of
the name itself adds nothing (induction on assignment order); a cycle never resolves. Every intermediate interval must
lie inside the narrowest target Fixnum range (`-2**30 .. 2**30 - 1`, the 32-bit `mrb_int` with word boxing), which is
what makes an interval a Fixnum proof on every target; a divisor interval holding 0 has no quotient. Literals above
32 bits are `LOADL` pool entries, so they fall out without any C conversion (and the fixtures spell them as literals).
A jump landing on a `SETCONST` or on the arithmetic instruction reading the registers withdraws the definition
(`X = c && 1` binds `false` on one path with a `LOADI` right before the `SETCONST`).

### NATIVE_INT_ARGS (`codegen_native_int_args.rb`, `codegen_fixnum_ranges.rb`)

`native_int_arg_proven?` says an `:int` argument of a native entry point is a Fixnum when `fixnum_interval` (a
single-path backward walk with `proven_fixnum_operand?`'s barriers: protected ranges, unaudited opcodes, region
dominance, `GETUPVAR`; sources: `LOADI*`, an interval constant, `+ - * /` of those whose result interval fits) says so
or when the Fixnum proof does without any constant leaf (`@fixnum_proof_skip_constants`: the name scan of
`INTEGER_CONSTANT_PROOF` misses a native definition, so it does not vouch for a constant here). A join gives up. It is
asked by `Bitmap.new` (every argument proven: the call is unconditional, no else; some proven: only the others are
tested) and by `native_exact_direct_code` (`Sprite#x=`, `Audio` fades, `Bitmap#_init_size`).

Everything needs a static constant world: a closed world, no `const_set`/`remove_const`/`autoload` anywhere (the send
form is a global refusal, an outside Ruby text or a native `mrb_const_set` with a computed name sets
`@dynamic_constant_mutation`), no `const_missing` (`const_missing_free?`), and, for an interval, `+ - * /` still the
core Integer bodies (`numeric_op_native?`: a definition-time `A / B` runs them). A constant read still runs its
`GETCONST`, so reading a name before its `SETCONST` raises `NameError` as before; only the tag test goes.

Kill switch `BC2CPP_NUMERIC_CONSTANTS=0`: the shipped C++ is byte-identical to master (checked with `cmp` against a
clean `origin/master` build; the exact-flow arm keeps the Fixnum proof it already had, `legacy_int_proof`).
`BC2CPP_NUMERIC_CONSTANTS_REPORT=<tsv>` writes every constant name with a definition and no interval, and why;
`CONST_RANGE name lo hi` lines are in the diagnostic.

## Consequences

Same tree, kill switch against default (`scripts/bc2cpp_coverage_report.rb`, shipped pass, `3rd/*` populated):

| | before | after | |
| --- | ---: | ---: | --- |
| `bc2cpp_send` call sites | 2,628 | 2,559 | -69 |
| of them in `RPG2k_*`/`Game_*` | 1,800 | 1,735 | -65 |
| `Bitmap.new` sites with no tag test and no else | 0 | 65 | +65 |
| `bc2cpp_getidx`, `bc2cpp_slow_*`, `bc2cpp_eqq`, `bc2cpp_nil_receiver`, `bc2cpp_nomethod` | 2,038 / 3,359 / 111 / 892 / 4,386 | same | 0 |
| `NOMETHOD_REVIEWED` keys | 2,917 | 2,917 | 0 |
| constants with a proven Fixnum interval | n/a (693 Fixnum constants) | 725 | |

Removal, not relocation: 65 `Bitmap.new` sites and 4 exact native sites lost their send; nothing moved into a helper or
a nil arm. The cutoff (30 removed by-name sends) is met by `Bitmap.new` alone. 50 `Bitmap.new` sites keep their test:
the remaining leaves are not provable without a range the program does not have (`Array#size` is a Fixnum on every
target, but `size * 16` is not provably one on a 32-bit `mrb_int`), or are the String form.

Soundness limits. A pool is a proof: the interval of a name is a fact about every definition the closed world can see.
A constant defined by code the scan cannot see (an unscanned gem, `eval`, `Marshal.load` of a class body) is outside it,
as for ADR 0276/0279. `IntegerConstants.native_const_names` has a latent miss (a lazy `.{0,200}?` that matches zero
characters, so a native `mrb_define_const` is not seen by `INTEGER_CONSTANT_PROOF`); the new analysis uses the bounded
scan, and this consumer ignores the old name set, but the existing consumers of `@integer_constants` (arithmetic
operands, return facts, argument pools) still rely on it. `IntegerConstants.const_source_kind` also lacks the "jump
lands on the SETCONST" guard (`X = c && 1` is an Integer constant there). Neither is changed here.

Next levers, in the order the measurement suggests:

1. a range for `Array#size`/`length` plus a runtime guard hoisted out of a method (`size * LINE_H` is the shape of 11
   sites): needs a guard, not a proof;
2. `X = c && 1` / the native-name scan fixes in `IntegerConstants` (behaviour change, own ADR);
3. interval constants for the other Fixnum consumers (`ADD` arms, `Integer#times`, array index): the same interval walk
   could replace ADR 0279's retired source 4 wherever the operands are constants (not built: it changes most of the
   generated arithmetic);
4. user readers of a constant-valued ivar (`left_panel_w`, `screen_width`): ADR 0309's accessor classes carry classes,
   not intervals;
5. the 17 file-load-form sites (a String argument makes the Integer test always false): a dead-test removal, no send is
   removed.

Not run here: any firmware smoke (psp, wio, maix) or CI shard; `pre-commit` hooks `nixfmt` and `cmake-format` if the
tools are missing (see the PR); the 32-bit leg ran on a host build with `MRB_32BIT`/`MRB_INT32`, not on a target, and
without block direct entry (ADR 0271; the fixture has no block).

## Tests

`scripts/bc2cpp_numeric_constants_check.rb`: generated code for nine positives (literal, `+ - * /` of constants, a
local copy, a hull of two definitions, a self-aliased constant, a name not yet assigned) and eight negatives (a
parameter, a constant above 32 bits, a Float, an arithmetic join, an overflowing product, a divisor interval holding 0,
`X = c && 1`, a use in a rescue range), fifteen withdrawal worlds (a reopened String constant, a reassignment out of
range, const_set, remove_const, a native or foreign definition, a build gem calling const_set with a computed name, a
const_missing, a module named like the constant, a redefined `Integer#*`, the open world, the kill switch); the fixture
on real mruby, interpreted and compiled, against a stand-in for `rgss::bitmap_new_direct` that records the constructor
arguments (full-core, core-only and 32-bit `mrb_int` builds), with every proven constant's value inside its interval
and zero dispatches on the proven methods. `scripts/bc2cpp_numeric_constants_mutation_check.rb`: an unmutated control
and fifteen mutants of the soundness conditions (the copy lives inside the repository so the closed world is not
empty), each killed. New `numeric-constants` shard in `bc2cpp-checks`; the 32-bit run is in `bc2cpp-width (int32)`.
