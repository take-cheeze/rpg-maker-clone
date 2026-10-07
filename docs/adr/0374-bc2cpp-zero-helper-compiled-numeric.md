# 0374. The `zero?` helper calls the compiled `Numeric#zero?` and raises the argument error of `File.zero?`

Date: 2026-10-07

## Status

Accepted

## Context

`bc2cpp_slow_zero` (33 generated callers, the else of the `INTEGER_UNARY` arm) was the last numeric helper besides `===`
and the index/collection ones that kept a by-name call. ADR 0367 left it open for two reasons, both rechecked here.

**Every definer of `zero?`, read off the sources the wio closed world scans:**

| Definer | Where | Reaches |
| --- | --- | --- |
| `Numeric#zero?` = `self == 0` | `mruby-numeric-ext/mrblib/numeric_ext.rb` (Ruby) | every Integer (a bigint included) and Float, and every other Numeric: `Numeric.new`, a user subclass |
| `File.zero?`, `FileTest.zero?` | `mruby-io/src/file_test.c`, `mrb_filetest_s_zero_p`, registered with `mrb_define_class_method_id` | the class objects `File`, `FileTest` and `File`'s subclasses, with a required path argument |
| nothing else | `src/numeric.c` has no `zero?` (the inline Integer arm is a mirror of `self == 0`); `mruby-complex` and `mruby-rational` define none; no project Ruby or native defines one | |

1. *`Numeric#zero?` is Ruby.* In a closed world that compiles mruby's own Ruby (ADR 0264, 0371) it is a compiled body,
   `Numeric_zero$3f_impl`. Its `self == 0` is already generated without a by-name call: the Fixnum and Float pairs inline,
   then `mrb_equal` (libmruby), which compares a bigint with `mrb_bint_cmp` and dispatches `==` inside libmruby for an
   object whose `==` is not `Object#==`. A program that defines a Numeric `==` makes it a `bc2cpp_send` site of the body, which
   the census counts with the body's own sites.
2. *The scan gap is closed already, partly.* ADR 0365 (PR #2047) added `definers[:class_native]`; it attributes
   `File.zero?` and `FileTest.zero?` to `File` and `FileTest` (both `mrb_define_class_method_id`). But
   `CallFacts::Answers#native_owners` still answered "unreadable" for any name that a native source *spells* and no
   instance registration explains, so `definers('zero?')` stayed nil and `members('zero?')` unbounded.

**What `File.zero?` does when the helper's receiver is a class object.** The helper always has zero arguments. The registered
body starts with `mrb_get_arg1`, which raises `ArgumentError: wrong number of arguments (given 0, expected 1)` for an argument
count other than one. A class object receiver therefore never reaches the file test; dispatch raises that error
(observed, `File.zero?`, `FileTest.zero?`, a `File` subclass), not a NoMethodError.

**A measured fact that bounds what "same as the interpreter" can mean.** In this mruby (3rd/mruby, the project's patched tree),
`(2**70) == 0` and `(2**70).zero?` are **true** in the interpreter: `int_equal` (`src/numeric.c`) reads
`mrb_integer(x)` of a bigint receiver for a Fixnum argument (`2**64 == 0`, `2**70 == 0` are true, `2**70 == 1` is false). The
compiled core `Numeric#zero?` answers false (`mrb_equal` goes through `mrb_bint_cmp`). That difference is between the
interpreted and the compiled core method and exists today, in every build that compiles core Ruby, whenever `zero?` is called
by name: dispatch finds the registered compiled entry. This ADR keeps the helper equal to the dispatch of its own build (the
registered compiled entry), which is the definition of "no behaviour change" for a helper; it does not fix the mruby bug (upstream
`int_equal` should test the receiver's type). The check below runs both the closed helper and `zero?` with the compiled core
entries registered.

## Decision

### The scan: a name spelled only by class-level registrations

`Answers#native_owners` now answers an empty owner set (instead of nil) when no instance registration, alias or opaque owner
of the name exists and every native source that spells it also registers it at class level (`class_registered_only?`, using the
ADR 0365 class registrations by path). The spelling is then the class registration the scan already attributes
(`definers[:class_native]`, a member `<ClassObject>`), not an unknown instance definer. This is a general change of the
analysis, so it was measured: in the census world one by-name body site became a proven-miss site (`bc2cpp_send` -1,
`bc2cpp_nomethod` +1): `RPG2k::Scene::Map#step_parallel` -> `start`, a name only `GC.start` spells (`gc.c`). The receiver is
always the `Game::Interpreter` that `new_parallel` builds, so the fallback is dead; the key is reviewed in
`NOMETHOD_REVIEWED`. Two `closed_world_kept:core_or_native` rows (186 to 184) moved with it.

### The proof (`codegen_numeric_slow_zero.rb`, `CodeGen#numeric_slow_zero`)

The closed form needs all of:

* `numeric_slow_closed_world?` (closed world, no `method_missing` class, singleton-free instances, no global refusal);
* `definers('zero?')` bounded: no engine Ruby, module, singleton or instance-native definer, and the foreign Ruby definers are
  exactly `{Numeric}`; `members('zero?')` are all `<ClassObject>` or inherit `Numeric` (`numeric_slow_inherits_owner?`);
* the ADR 0371 structure for the compiled body: `core_compiled_definers('zero?')` has exactly one entry, on `Numeric`, it is the
  foreign definer the scan saw, `block_core_target('Integer', %w[Integer Float Numeric], 'zero?', 0, blockless: true)` reaches it
  with no project definition, native registration, prepend, unattributed mixin, outside definer or computed installer on any of the
  three chains, its body compiles clean and this link emits its owner, and **`YieldReach#yield_free?` holds for it** (a direct
  `_impl` call skips the entry's Fiber guard, ADR 0269, and the helper has no block; a program `==` that may yield turns the
  arm off). Integer and Float need no arm of their own to reach it because neither defines `zero?`;
* the constant `Numeric` is bound by nothing but the core (`ClosedWorld#core_constant_plain?`; a new `global_only:` keyword
  skips the nested-class clause, because the arm reads the top-level constant from C++ and `LCF::File` cannot rebind it);
* when the world has class-level `zero?` registrations (`File`, `FileTest`): the build links `mruby-io`, the registrations
  are exactly those two owners, each names `mrb_filetest_s_zero_p` in `mruby-io/src/file_test.c`, the opaque owner list is
  empty, the constants `File` and `FileTest` are plain, and the function body, whitespace removed, begins
  `{mrb_io_statst;mrb_valueobj=mrb_get_arg1(mrb);` (the one-argument read is the first effect).

### The helper

    if (mrb_float_p(a)) return mrb_bool_value(mrb_float(a) == 0);                      // as before
    if (mrb_obj_is_kind_of(M, a, mrb_class_get(M, "Numeric"))) { ... Numeric_zero$3f_impl(M, a) ... }
    if (class or module object) for (k = its class chain) if (k is File or FileTest) mrb_argnum_error(M, 0, 1, 1);
    return bc2cpp_nomethod_named(M, a, "zero?");

A Numeric that is not a Float (a Fixnum, a bigint, `Numeric.new`, a user subclass, a frozen one) runs the compiled body; its
`==` is the body's own site, as it is whenever `zero?` is called by name in this build. The class-object arm is the smallest
faithful choice and needs no patch: a faithful *call* of `mrb_filetest_s_zero_p` is impossible (`static`, and it reads the
caller's frame), a patch exporting `*_impl(mrb, klass, path)` would add a file to the chain of pinned digests
(`native_class_results.rb`, `native_ivar_scopes.rb`) for a body the helper can never reach with an argument, and a by-name arm
for the two class objects would keep exactly the call the work is removing. The helper raises what the first statement of the
registered body raises for the zero arguments it always has. Every other receiver is `bc2cpp_nomethod_named`, which dispatches
by name before it raises, so a wrong proof is the right answer or `closed-world proof violated` (ADR 0262, 0275), never a
wrong value. `BC2CPP_CORE_COMPILED_ZERO=0` (and `BC2CPP_NUMERIC_SLOW_CLOSED=0`) keeps the by-name helper byte for byte, the old
text stays under the Complex/Rational `#if`, `BC2CPP_ZERO_WHY=1` prints why a world keeps it.

### Resolving `self == 0` per Numeric class: not built

The suggestion was to resolve the body's `==` statically with a class-pointer switch over the descendants of `Numeric`, each
arm following that class's own method chain, and `bc2cpp_guard_violation` as the else. It was measured and left out:

* **The descendant set is `{Integer, Float, Numeric itself}` in the census world.** No engine Ruby declares a Numeric
  subclass (checked by source grep and by `members`), `Class.new(Numeric)` and `Struct`-style factories do not occur, and
  Rational and Complex exist only under the macros, which keep the by-name helper. So the switch would have three arms.
* **None of them has a by-name site today.** Fixnum and Float pairs are inline in the body; a bigint, `Numeric.new` and any other
  receiver reach `mrb_equal`, libmruby's own dispatch, which the census does not count and which is the interpreter's `==`
  semantics (Integer, `Comparable#==` through `<=>`). A switch would replace it with direct calls of bodies mruby keeps `static`
  (`Comparable#==`, `cmp_equal`) and with `int_equal`, whose bigint receiver answer is the bug above: resolving `==` "as Ruby"
  for a bigint would make the compiled body agree with the interpreter's wrong `true`. That is a decision for a patch that fixes
  `int_equal`, not for a helper.
* **A user `==` already is the body's by-name site** (`bc2cpp_send`, counted with the body), and only a world with one exists.
  Resolving it per class needs the same lexical-self resolution as the `implicit_self_unresolved` family; that family is 198
  sites in the census (88 + 82 + 27 + 1 by registered-definition path); the number sitting in module methods with a
  bounded includer set was not split out (it needs the includer sets, which is the work of that change, not a count).

### Worlds this applies to

The closed form needs compiled core Ruby, so it exists only where core is compiled: the wio closed-world census
(`scripts/bc2cpp_coverage_report.rb`, shipped pass), and a closed build with `BC2CPP_HOT_ONLY=0`. **The three shipped
firmware closed worlds (wio, psp, maix) are hot-only (ADR 0214) and hold no core Ruby, so `zero?` stays the by-name helper
there byte for byte**; the check's "no core compile" world asserts it. The scan change (`class_registered_only?`) is world-wide
and is exercised by the shipped passes too (the one site above).

## Consequences

Measured on the wio closed world (`BC2CPP_COVERAGE_KEEP_DIR`, `scripts/bc2cpp_dynamic_site_census.rb`, shipped pass), base
`38f7267a` (master after ADR 0371, the `#if` arm kept for Complex/Rational builds not counted in either run):

| Measure | Before | After | Delta |
| --- | ---: | ---: | ---: |
| by-name calls held in helpers (`bc2cpp_send` in the helper region) | 13 | 12 | -1 |
| helpers that hold a by-name call | 11 | 10 | -1 |
| generated callers of a helper that holds a by-name call | 3,423 | 3,390 | -33 |
| `bc2cpp_send` call sites in generated bodies | 2,184 | 2,183 | -1 |
| `bc2cpp_nomethod` sites | 4,539 | 4,540 | +1 |
| **Sites that can reach by-name dispatch** (bodies + helper callers + 414 block + 30 funcall sites) | **6,051** | **6,017** | **-34 (-0.6%)** |
| generated `shipped.cxx` | 21,463,372 B | 21,464,359 B | +987 B |

The 33 callers are the `INTEGER_UNARY :zero?` sites. The generated method bodies are otherwise unchanged; the -1/+1 pair is the
`start` site of the scan change. Core compile counts do not move (215 / 190 / 25). The firmware size budgets were not rebuilt and
cannot move: the three builds are hot-only and the generated helper is byte-identical there.

Verification, `scripts/bc2cpp_zero_direct_check.rb` (core-flow shard, and the `int32` and `nobigint` width legs):

* generated code: the closed form has the Float arm, the `kind_of Numeric` test in front of the compiled call, the File arm,
  no by-name text, a proof-violation else, and the by-name copy under the Complex/Rational `#if` is unchanged; negative worlds
  (`zero?` reopened on Numeric, Integer or Float, a Numeric subclass with its own, a module included or prepended, an alias, a
  class-level `zero?` on a user class, a singleton, a computed installer, `method_missing`, a `==` that may yield, a build
  without mruby-numeric-ext, without mruby-io, an open world, no core compile, both kill switches) keep the by-name helper;
* a run on the real mruby at `mrb_int` 64, 32 and without bigint: the helper called directly against `zero?` of the same
  build (core entries registered) over 51 receivers, three rounds with a full GC, in the closed world and in four worlds that
  keep the by-name helper (Integer#zero? reopened, Numeric#zero? reopened, a singleton `zero?`, a `method_missing` class):
  Fixnums, 2**70, -2**70, 0 from subtraction, 0.0, -0.0, NaN, infinities, `Numeric.new`, Numeric subclasses with no `==`,
  a `==` that logs, raises (error class and message), returns a non-boolean, a `<=>` of 0, a subclass of a subclass, frozen
  ones, `File`, `FileTest`, a `File` subclass and an anonymous one, `Object`, `Integer`, `Numeric`, `Comparable`, `Kernel`,
  anonymous classes and modules, `File.singleton_class`, nil, true, false, String, Symbol, Array, Hash, Range, Proc, plain
  objects. Result, error class and message and the number of user `==` calls are equal in all 153 cases per build (0
  mismatches); the by-name call counts are 0 for Float and the File class objects, at most one for a Numeric (the body's own
  `==` site) and exactly one for the proof's dispatch;
* `bc2cpp_zero_direct_mutation_check.rb`: the kill switch, the yield-free proof, the Numeric kind test, the File pin and the
  by-name else restored each fail the check.

Also run and green: nested_compile_state (the new memo ivar is classified), closed_world, guard_violation, lint_crosscheck,
call_facts, static_dispatch, core_mrblib, core_exact_direct, `bc2cpp_nomethod_reviewed_check` after the one reviewed key.
`bc2cpp_native_class_results_check` fails the same three `audited result` cases (`compact`, `flatten`, `__uniq`) on the base
tree in this environment (digest pins against the shared 3rd/mruby), so it is not caused by this change.

Not run: the PlatformIO wio/psp/maix firmware builds and size budgets, the desktop and Emscripten builds (the generated helper is
unchanged there), `mruby_patch_context_check` (no patch was added).
