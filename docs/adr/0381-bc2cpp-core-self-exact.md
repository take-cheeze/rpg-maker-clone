# 0381. `self` inside a compiled Array, Hash, String or Range body is exactly that class, checked at the site

Date: 2026-10-10

## Status

Accepted

## Context

About 330 of the by-name sends left in the Wio shipped build sit in compiled core bodies, where `self` was treated as
"any includer" (`docs/bc2cpp-dynamic-site-census.md`). They fall into three groups, classified here by body owner and
by how many classes can reach the body (measured on master 5ddf1d98, shipped pass):

| Owner of the body | Self-origin sites | Classes that reach the body | What the sites are |
| --- | ---: | --- | --- |
| a concrete core class: Array 52, Hash 39, String 35, Range 30 | 156 | the class itself, plus any subclass the program has | `size`/`length`/`keys`/`begin`/`end`/`exclude_end?` (native, exact arm exists), `replace`/`byteslice`/`delete` (native, no arm), `to_enum` (39), private helpers |
| a module: Enumerable 26 sends + 54 funcalls, Comparable 5, Kernel 2, Enumerator 3 | 36 sends | 11 (Range, Array, Hash, Struct, Dir, Enumerator, Enumerator::Chain, IO, Set, `LCF::Array1D`, `Game::...`) for Enumerable; 4+ for Comparable | `to_enum` 22, `each` (funcall), `<=>`, `to_a` |
| other: StringIO 17, IO 10, Integer 8, RGSS, LCF, RPG2k | about 140 | StringIO, IO, ... | natives without an arm, or `self`-origin sites of engine classes (a different lever) |

The module owners are where "specialize the body per includer" would apply. It does not pay (see Consequences). The
concrete-class owners need no clone: their `self` is already the class.

## Decision

**CORE_SELF_EXACT.** A send on `self` in a compiled body of `Array`, `Hash`, `String` or `Range` is a proven-exact-receiver
site (ADR 0280's arms: `CLOSED_WORLD_NATIVE_EXACT`, `NATIVE_CORE_DIRECT`, `CORE_EXACT_DIRECT`, `BLOCK_CORE_DIRECT`) when

1. the body is a core body (`@core_program_world`) of that class, instance side (`Array`, not `Array.singleton`), and the
   receiver is `self` itself (register 0 at entry, `LOADSELF`, or a MOVE chain from either) read in the method's own irep,
   not in a block (a block may be run with another self by `instance_exec` / `define_method`);
2. the program has no subclass of that class: `core_class_subclass_free?` (`ClosedWorld#native_subclass_free?` over the
   engine and the outside Ruby, plus the scan of every native source for `mrb_define_class*` / `mrb_class_new` with the
   class as superclass), now asked of the program world when compiling a core body; and
3. ADR 0359's own conditions hold: `exact_instances_singleton_free?` (no singleton maker anywhere), `BC2CPP_CORE_BODY_EXACT`
   and `BC2CPP_GUARD_VIOLATION` not `0`.

Under 1-3 every instance that reaches `Array#foo` is exactly an Array. Nothing is trusted: the site is wrapped exactly as
ADR 0359 wraps a literal receiver, `if (mrb_array_p(self) && mrb_obj_ptr(self)->c == M->array_class) { arm } else
{ bc2cpp_guard_violation(...) }`. An instance of a class the analysis did not see (a subclass made at run time, a
singleton) logs `[RPG2k] closed-world guard violation: Sub#size at Array#foo (CORE_BODY_EXACT)` and raises
`BC2cppGuardViolation` (< NoMethodError); `-DBC2CPP_NOMETHOD_VERIFY` aborts. The proof only chooses which sites get the
test.

Two small changes ride on it. A bare `size` is an `SSEND` whose receiver is register 0, so `compile_send` builds the site
for an implicit self in a core body (`self_implicit` sites had none). And `CORE_EXACT_DIRECT` accepts a private compiled
target for such a site, because an implicit-self call may reach a private method (an explicit-receiver call may not).

`BC2CPP_CORE_SELF_EXACT=0` removes the proof and restores the previous output byte for byte; the ADR 0359 switches
withdraw it too.

**Refused, with the reason (counted by the existing `core_body_exact_class` refusals):**

- module owners (`Enumerable`, `Comparable`, `Kernel`, `Enumerator`): the includer set is not one class. Per-owner
  cloning of the 43 Enumerable bodies (2,156 generated lines) for 11 includers is about 23,000 lines, 5% of the build,
  to resolve at most 8 by-name sends: the 22 `to_enum` sends have no compiled target (`Kernel#to_enum` is interpreted
  mruby-enumerator Ruby), and the 54 `each` funcalls could not lose their funcall arm anyway (ADR 0280: a compiled
  core block method entered from a Fiber needs the dispatch).
- a block body, a parameter, a join: same refusals as ADR 0359.
- `to_enum` (39 sites in these four owners, 66 in all): not resolvable by any receiver proof.
- the `to_s -> upcase / rjust / ljust` consumers (3 in `RPG2k::Scene::SaveLoad`, 1 `Audio.play_packed`, 2 in
  `String#upto`): `upcase`, `rjust`, `ljust` are static C functions (`str_upcase`, `str_rjust_core`) with no registered
  expression body, no `NATIVE_CORE_DIRECT` entry and no exported symbol, and `String` is not a `BlockCoreDirectFallback`
  receiver. A checked String result would only move the by-name send behind a class test, not remove it; that is not
  built.

## Consequences

Measured on the Wio shipped build (master 5ddf1d98), switch off against on, same tree:

| Measure | Off | On | Delta |
| --- | ---: | ---: | ---: |
| `bc2cpp_send(` textual occurrences | 2,082 | 2,028 | -54 |
| `mrb_funcall` text hits (`BLOCK_CORE_DIRECT` else arms) | 10,707 | 10,705 | -2 |
| `CORE_BODY_EXACT_CHECKED` sites | 38 | 95 | +57 |
| `bc2cpp_guard_violation(` sites | 573 | 630 | +57 |
| generated C++ | 444,215 lines, 21,553,927 bytes | 444,010 lines, 21,558,616 bytes | -205 lines, +4,689 bytes (+0.02%) |

The 54 removed sends are Range 23 (7 bodies: `begin`, `end`, `exclude_end?` in `max`, `min`, `last`, `first`, `each`,
`hash`, `overlap?`), Hash 16 (`size`, `keys`, `values`, `key?`, `__delete`, `all?` in `each`, `delete`, `transform_*`,
`select!`, the subset operators), Array 14 (`size`, `length`, `empty?`, `pop`, `last` in `permutation`, `uniq!`, `select!`,
`find`, `rfind`, `keep_if`, `bsearch_index`, ...) and String 1. Each costs one pointer compare and a cold violation call
and loses a tag chain; the net size change is +87 bytes per removed send.

`scripts/bc2cpp_core_self_exact_check.rb` covers it: generated code (bare and explicit self, a MOVE copy, all four
owners; refusals for a parameter, a block, a module owner, a subclass of each owner in the program, which withdraws only
that owner, a singleton maker, the three kill switches and the open world), and on real mruby an honouring fixture that
answers what the interpreter answers (also under `-DBC2CPP_NOMETHOD_VERIFY`) against late `Array` and `String`
subclasses the driver makes, which log and raise naming the class and the site, and abort in verify mode.

What stays open: natives without an expression body (`replace` 10, `byteslice` 6, `delete` 4, `index` 3, `__empty_range?`
4), which need an exported body, not a receiver proof, and `to_enum` (66).
