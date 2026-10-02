# 0317. bc2cpp: provable errors as build errors (measured, not built) and post-call receiver facts (built)

Date: 2026-10-02

## Status

Accepted

## Context

Two questions, one measurement each (wio closed world, master `147fe7e6`, shipped pass of
`scripts/bc2cpp_coverage_report.rb`, `3rd/*` populated, all three engine gems plus core Ruby and `other`):

1. Would treating *provable runtime errors* as compile-time errors reduce the dynamic calls?
2. Would *post-call receiver refinement* do it: after `r.m(...)` returned normally, `r` is an instance of a class that
   answers `m`, so a later use of the same value has a narrower receiver set?

ADR 0275/0290/0226 already turn the dead else of a guard chain into `bc2cpp_nomethod` and make a proven-class miss a
build error (`PROVEN_MISS_REVIEWED`, empty). The exact-class flow (ADR 0289/0296/0301/0308) has no is_a?/respond_to?
narrowing and no post-call narrowing; it narrows only by truthiness (`JMPIF`/`JMPNOT`/`JMPNIL`, `RAISEIF`).

## Part 1: provable errors (not built)

`BC2CPP_PROVABLE_ERROR_REPORT=<tsv>` (`tools/bc2cpp/provable_error_report.rb`, `BC2CPP_PROVABLE_ERROR_ALL_GEMS=1` for
core Ruby too) scans every send and operator. It reports a site when (a) no class of the proven receiver set answers
the name, (b) the set is exactly nil, (c) every definition of the name (or the one each class of the set resolves to)
rejects the argument count, (d) an operator pair is always rejected (`Integer + String`, `Integer / 0`...), (e) the
name is defined nowhere. Each hit is classified `unconditional` (on every completing path of a method body, outside
every rescue range, not a block), `conditional`, `rescue`, `probed` (the name is given to `respond_to?`) or `dead`.
A control fixture (`PeHolder`: ten planted errors) is found by every detector, so the zero below is not a blind probe.

| Examined (engine gems) | Count |
| --- | ---: |
| explicit sends with a proven receiver class set (a: nomethod / b: nil) | 2,915 (rpg2k 2,753, rgss 108, lcf 54) |
| implicit-self sends in declared classes (a, `lexical_self`) | 3,738 |
| exact-set arity checks (c2) plus every plain send against its name-wide arity (c1) | 1,309 + all |
| operators with both operands proven (d) | 688 |
| **hits in the three engine gems** | **0** |
| hits in all gems | 2, both guarded |

The two: `LCF#binstr -> force_encoding` (`mruby-lcf/mrblib/lcf.rb:387`, behind `respond_to?(:force_encoding)`, class
`probed`) and a self-call of `=~` in core Ruby (conditional). Unconditional, conditional-but-reachable and
rescue-covered engine hits: 0 / 0 / 0. Other measures: by-name sends that sit in a provable-error site: 0; the
error-raising helper calls that exist today are 4,318 `bc2cpp_nomethod` (dead else arms of polymorphic dispatch, 2,884
reviewed keys), 310 `bc2cpp_guard_violation` and 890 `bc2cpp_nil_receiver`, none an error by themselves.

**Decision: no compile-time-error lint.** It removes 0 by-name sends and finds 0 bugs; its new coverage over
`PROVEN_MISS` (flow-based sets, arity, operators) would be a tripwire for a clean tree. The detector stays as the
report; promote a kind to a build error only when it has a hit worth keeping.

## Part 2: post-call receiver facts (built)

`BC2CPP_REFINE_REPORT=<tsv>` (`tools/bc2cpp/refine_report.rb`, `scripts/bc2cpp_refine_report.rb`) judges every
explicit send. Measured with the facts off (`BC2CPP_CALL_FACTS=0`, `shipped.cxx` byte-identical to master):

| Engine gems | Value |
| --- | ---: |
| explicit-receiver sends / with a by-name line | 11,760 / 2,154 sites (2,225 lines) |
| kept-else sites (`CLOSED_WORLD kept`) / receiver unproven | 438 / 378 |
| by-name sites whose receiver the facts bound to **user classes only** | 105 |
| of those: the by-name else is dead (a Ruby body per class, listed) | **100**: 64 kept else, 34 nomethod else with a by-name arm (no removal), 2 bare |
| by-name sites bounded to a set with core/native members (no removal) | 130 |
| a fact names no bounded set (`respond_to?`, Kernel names, installed names) | 90 |
| no earlier call on the value | 1,652 |

Single name versus interface (forward, sound): one fact alone gives a usable set at 103 of 105 sites and the
multi-name interface only at 2 (`route.index` after `route.step`, `entry.chunk` after `entry.commands`); of the 64
kept-else removals 62 need one name. Facts per site: 1 = 59, 2 = 25, 3 = 7, 4+ = 14.

Backward interface (every name used on the value anywhere in the method, **unsound for codegen**: the first call in
the narrowed code would raise where the old code did): upper bound 175 sites with a user-class set, 114 kept-else
removals, so at most 50 more than the sound one. As a lint: 8 sends have an interface no class satisfies, all false
positives (`LCF#encode`, branching on `is_a?`; `Interpreter#resume_name_input`, `actor = req && ...` merges two
values; `binstr`, `respond_to?`).

NOMETHOD_REVIEWED classified by the receiver's interface (4,068 sites, 2,948 keys): 2,465 monomorphic (one arm), 771
polymorphic else arm (two or more listed classes satisfy the interface), 417 narrowed (the interface leaves one listed
class), 70 satisfied by native or core classes whose arms are not in the chain, 334 not traced (rescue ranges), 10
unbounded names, **1 possible bug candidate**, which is `LCF#encode -> to_lcf` (type-tag union, not a bug). So
the interface classifies 99.7 % of the keys automatically and finds no bug.

Chains (POLY_SMALL_N 1,525, POLY_TABLE 70, IVAR_ACCESSOR 1): 50 chains have two or more classes on one definition; a
shared arm or a class-id interval check would save 177 of 8,906 compares. A speed question, not a removal one.

Cutoff: at least 30 removed by-name sends in the engine gems. 64 predicted, **63 realized** (below), so it is built.

### Decision

* `tools/bc2cpp/call_facts.rb`: `CallFacts::Flow` is a forward *must* analysis over one irep. State: which registers
  hold the same value, and the sorted names that value answered on every path. A call `r.m` adds `m` to the value of
  `R(a)`'s other holders and rewrites `R(a)` and every register above it (the callee frame); any other write detaches
  its register; joins intersect; a handler edge takes the state *before* the raising instruction, so only the
  normal-return edge carries a fact; a register a nested block writes never takes one. Ivar slots take none (a callee
  may write them). `CallFacts::Answers` answers "which classes answer `m`": Ruby definers and their descendants,
  includers of module definers, native registration owners (`NativeExpressionDevirt.class_registrations`), outside
  Ruby owners (`ForeignDefiners`), method_missing classes. A name installed by computed code, hooks, a definer on
  Object/Kernel/BasicObject, a native whose owner is unreadable or an outside wildcard is *unbounded*: no fact.
* `CodeGen#receiver_instance_scope` (`codegen_call_facts.rb`): when the exact-class flow proves nothing, the receiver
  set of a `SEND`/`SEND0` is the intersection of the classes that answer each fact, accepted only when it is at most 32
  declared classes that are instance classes no outside source can reopen or subclass. It feeds
  `ClosedWorld#refusal(..., scoped:, native_free:)`: `scoped` means the set is the whole receiver set, so only its
  classes must be listed; `native_free` lifts `core_or_native` when no native, outside or module definer reaches a class
  of it. Everything else (`dynamic_install`, `unknown_definer`, method_missing) is unchanged.
* Kill switch `BC2CPP_CALL_FACTS=0`: `shipped.cxx` byte-identical to master (`cmp`), also checked by the check script.
  The open world and `global_refusal` or a singleton maker turn it off.

### Results

`shipped.cxx` against master: `bc2cpp_send` 2,666 -> 2,603 (-63), kept-dispatching else arms 462 -> 399, `bc2cpp_nomethod`
4,318 -> 4,380 (+62 sites, +33 keys in `NOMETHOD_REVIEWED`, each read: the receiver was already used with a name only
the listed classes answer, e.g. `it.wait_kind` then `it.resume`, `state.map_id` then `state.map`). Dynamic calls other than
`bc2cpp_send` are unchanged (`mrb_funcall_with_block` 401, `mrb_funcall*` 28).

Checks: `scripts/bc2cpp_call_facts_check.rb` (generated code: 6 positives, 9 negatives, 10 withdrawal worlds, kill
switch, open world; behaviour against the interpreter on full-core, core-only and 32-bit `mrb_int` builds with zero
dispatches asserted on proven sites and a probe that the compiled bodies ran) and
`scripts/bc2cpp_call_facts_mutation_check.rb` (10 mutants and an unmutated control, mutated inside the repository).

## Consequences

* Not sound without an ivar proof: a fact on an ivar-held value would survive a call that rewrites the ivar; measured
  with such an optimistic variant (not in the tree) it adds 4 kept-else removals (68 against 64). Next lever: an
  escape/write analysis of callees (ADR 0316) to keep facts across calls that cannot write the ivar.
* `native_free` and the 32-class cap have no killing mutant: the other gates (`untouched_class?`, `:opaque_definer`)
  cover every world a fixture can build.
* The report's SENDB sites (about 40 more candidates) are not built: `receiver_instances` only models `SEND`/`SEND0`.
* Next-best levers: 130 sites bounded to sets with core/native members (`size`, `count`, `first` on a user class beside
  Array) need per-class native arms; 90 facts bound nothing; 1,652 by-name sites have no earlier call on their value.
* Not run locally: the firmware smokes, the optcarrot (open-world) comparison, `bc2cpp_nomethod_reviewed_check`
  (regenerated with `scripts/bc2cpp_nomethod_reviewed_update.rb --write` from the same run it re-proves).
