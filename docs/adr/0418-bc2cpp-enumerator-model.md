# 0418. bc2cpp: Enumerator model, measured

Date: 2026-10-12

## Status

Accepted

## Context

The request was to model Enumerator in bc2cpp so that by-name dispatch of `to_enum`, of blockless iterators
(`each_with_index`, `map`, `each_slice` ...) and of calls on their Enumerator results disappears, and so that class
proofs flow through chains such as `rolled.each_with_index.sort_by { }.map { }` (which was believed to leave
`Game::Battle#@queue` unproven). The census came first. Everything below is the Wio closed world at master `5ead3a77`
(`scripts/bc2cpp/coverage_report.rb` pipeline, shipped pass, counted with the dispatch census scripts).

| Site family in the shipped C++ | `bc2cpp_send` | `mrb_funcall*` |
| --- | ---: | ---: |
| `to_enum` (all in mruby's own mrblib: `return to_enum(:x) unless block`) | 65 | 1 |
| blockless iterator whose result is an Enumerator, in project code | 0 | 0 |
| calls ON an Enumerator receiver (`next`, `size`, `with_index`, ...) in project code | 0 | 0 |
| block-carrying `each_with_index`/`map`/`select`/`reject` else arms (receiver class unproven) | 0 | 36/41/18/12 |

The 65 `to_enum` sends are in the bodies of `Enumerable` (22), `Array` (17), `Hash` (13), `Integer` (4), `String` (3),
`IO` (3), `Struct`, `Range` and `Float` (1 each). No project method builds an Enumerator by name: the only project
chain, `Game::Battle#turn_order`, ends in a block `map` (always an Array) and already proves its return. The
36/41/18/12 funcalls are the else arms of block sends (`BLOCK_CORE_DIRECT`) whose receiver class is unproven. Producer
census (the origin trace made to print `send_result:<name>`, 164 POLY_DIAG sites whose receiver is a send result):
block `map` 10, `select` 6, `reject` 6, `sort_by` 1, accessors and natives for the rest, and no blockless iterator
(`each_with_index`, `each_slice`, `map` without block, ...) at all. Enumerator values do not reach a receiver in the
shipped program, so there is nothing for an Enumerator class to prove.

`Game::Battle#@queue` was poisoned by `@queue = @queue.reject { ... }` (poison cause `core_call`), not by an
Enumerator: `proven_array_source_scan` asked a plain trace for the receiver's class, which cannot read an ivar. A
`select`/`reject` store on an ivar that every other store makes an Array was never evidence.

## Decision

1. **TO_ENUM_DIRECT.** `EnumeratorModel` proves, from the bytecode and the registry, that `Kernel#to_enum` is the
   program's only `to_enum`, `enum_for` is only its alias, its body is exactly `Enumerator.new self, meth, *args,
   **kwd` (an operation whitelist: one `new` send, one `Enumerator` constant read, no block), and nothing replaces the
   construction chain (`Enumerator#initialize` once; no project `new`/`allocate`/`initialize` on Enumerator, Class,
   Module, Object, Kernel or BasicObject). It proves the `Enumerator` constant stable apart from `StableClassConstants`
   (chain.rb and lazy.rb reopen the class, which that analysis counts as a second definition): every
   `class Enumerator` statement is a top-level one (the compiled sources run as one script, so statements in a class
   body, block or method are nested), nothing assigns it, no native source defines it and no `const_set`,
   `remove_const` or `autoload` exists. On a receiver the exact-class flow proves is an Array, Hash, Range or String
   in a compiled core body (the CORE_BODY_EXACT site of ADR 0359/0381: a class test, and a guard violation in the
   else), a `to_enum`/`enum_for` without block becomes `bc2cpp_to_enum(M, argc, {self, meth, *args})`, which is
   `mrb_obj_new(M, mrb_class_get(M, "Enumerator"), ...)`: Class#new, then `initialize`. A runtime installer naming
   any involved method (`devirt_blocked_name?`, `symbol_installed_names`) withdraws it per body. The model, the
   constant and the helper are computed and printed in the diagnostic
   (`== enumerator model (ADR 0418) ==`); `BC2CPP_ENUMERATOR_MODEL=0` restores the previous output byte for byte.
2. **CHAINED_IVAR_RECEIVER.** ClassLayout hands `proven_array_source_scan` the class it has proven so far, so
   `@q = @q.reject { }` / `select` is an Array store when the receiver traces to Array through the ivar table. The
   fixed point already poisons any disagreeing store, and a later poison of the receiver ivar re-runs the dependent
   store in the next sweep, as it does for every other ivar-to-ivar chain.

**Not built, with the reason.** (a)/(b) an Enumerator result class in the class flow, and (c) fusing
`src.each_with_index.map { }` / `map.with_index` / `each_slice(n).map` into an inline loop: the census finds no
project consumer of an Enumerator value except `turn_order`'s `each_with_index.sort_by { |(b, roll), i| }`, whose block
destructures (`pure_mandatory_arity?` refuses it) and runs once per round; and the flow is not what blocked `@queue`.
Core bodies' Enumerator results are consumed by the caller's block send, which the ADR 0338/0343 core results already
type. Adding an Enumerator bit would add a class-test arm to every send the flow types and shipped nothing measurable,
so nothing was added for it. External iteration (`next`, `peek`, `rewind`) is untouched: the real Enumerator and its
Fiber machinery run, and the guarded wrappers of ADR 0350 are unchanged.

## Consequences

Measured on master `59cc590d` against the same tree plus this change, shipped pass of the Wio closed world:

| | master | this change |
| --- | ---: | ---: |
| live `bc2cpp_send(M` | 1,792 | 1,758 |
| live `mrb_funcall*` | 379 | 379 |
| `to_enum` by-name sends | 65 | 31 |
| `TO_ENUM_DIRECT` sites | 0 | 34 |
| known ivar class hints | 285 | 286 (`Game::Battle#@queue` is `Array`) |
| ivar class candidates poisoned to unknown | 603 | 602 |
| `bc2cpp_nomethod(M` sites | 304 | 304 |

The 31 remaining `to_enum` sends are the `Enumerable` module bodies (22; the includer set is not one class, ADR 0381
measured cloning at 5% of the build for at most 8 sends), `Integer` (4), `IO` (3), `Struct` and `Float`: none is a
CORE_SELF_EXACT class. `Game::Battle#turn_order` was rewritten in #2159 on the belief that its Enumerator chain kept
`@queue` unproven; on `59cc590d` it still was, and only the `reject` store change here proves it. The proven `@queue`
removes no further site by itself (the nomethod count is unchanged): its readers were already guarded arms.

The direct build skips the lookup of `to_enum` and one interpreted frame (`Kernel#to_enum`); `Enumerator#initialize`
still runs in the VM. An Array/Hash/Range/String subclass instance reaching such a body logs and raises
`BC2cppGuardViolation` exactly as for the other CORE_SELF_EXACT sites.

`scripts/bc2cpp/enumerator_model_check.rb` covers the proofs (including the nested-statement,
assignment, `const_set`, alias, body and construction-chain refusals), the generated sites, and a full-core run
comparing the compiled core's blockless iterators with the interpreter (next/peek/rewind/size on an array
enumerator, `with_index`, `with_object`, `each_slice`/`each_cons`, lazy, a user `each` + Enumerable, a redefined
`map`, Hash and Range sources, `break`/`next`/exceptions, a Fiber, GC) and asserting that the direct core iterators
make no dispatch. `enumerator_model_mutation_check.rb` removes one condition at a time (23 mutants and a control; each gate has a world only it refuses).
