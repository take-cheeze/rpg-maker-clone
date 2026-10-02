# 0316. bc2cpp: one shared escape analysis, and the one consumer its numbers justify

Date: 2026-10-02

## Status

Accepted

## Context

bc2cpp has no general answer to "does the value this instruction made leave this frame?". It has eleven narrow
ones, each written for one question and each rediscovering the same register flow. The table is every proof in
`tools/bc2cpp` that decides something about where a value goes (read from the source at master `43031b24`).

| Proof (where, ADR) | What it proves | Shapes it recognises | What it declines | Used for |
| --- | --- | --- | --- | --- |
| `lambda_confined_call_sites` (`codegen_runtime_def.rb`, CONFINED_LAMBDA_UPVAR_SUPPORT) | the proc made by `LAMBDA` is only `.call`ed, so raw pointers to the frame stay valid | a named local, no ARGARY/BLKPUSH in the irep, no child closure naming it, every other use is `MOVE t, d` followed on a straight line by `SEND t :call n=arity` | everything else (`#error`, the method stays interpreted) | admitting a pointer-capturing LAMBDA_FALLBACK; turning each `.call` into a direct `_impl` call |
| `BLOCK_FALLBACK_UPVAR_SAFE_METHODS` (`irep_arity.rb`) | the callee runs the block synchronously and never keeps it | a hand-vetted allowlist **by name** over every receiver (`new` only for `Array.new`) | any other name that has to capture a local or forward the method's block | admitting pointer-capturing BLOCK_FALLBACK regions, `needs_blk`, the inlined `times` loop |
| CORE_BLOCK_GUARD, `CoreDefs.touches_block?` / `builds_lambda?` (`core_defs.rb`, `core_methods.rb`, ADR 0269) | assumes core iterators do not store their block; a core method that builds a lambda is refused whole | by-op scan of the irep tree (BLKPUSH, BLOCK, LAMBDA, SENDB) | any core method that builds a lambda (3 of them) | which core mrblib methods compile, when their entry hands back to bytecode under a Fiber |
| `YieldReach#scan_keeps` (`yield_reach.rb`, ADR 0283) | the block a method received is kept (stored, returned, passed as a non-block argument or receiver) or only run/forwarded | per-method register classes by a backward walk; forwards by callee name | unknown receivers, `super` | which frames can suspend a Fiber (`block_yield_free`, `fiber_unsafe`) |
| `RecordHash` ALIAS_SCAN (`record_hash.rb`, ADR 0285) | an ivar-held Hash is only read by `h[k]`, written by `h[:lit] = v`, deleted by `h.delete(:lit)` | a forward may-alias set over registers and captured locals, `escape(why)` on anything else | non-literal keys and stores, any other use | per-key value classes of record Hashes |
| `ivar_assigned_before_exposure?` + `SELF_EXPOSING_OPS` (`bytecode_ir_dataflow.rb`, ADR 0261) | on every path `@x` is assigned before it is read, before the frame exits and before `self` reaches other code | a forward must-analysis; LOADSELF, any SSEND/SUPER/BLOCK/LAMBDA/EXEC or any op naming R0 ends it | everything that can show `self` to a callee | `numeric_ivar_assured?`, `class_pool_ivar_entry_mask` (ADR 0301): nil in a typed slot |
| `DefineMethodSites::FRAME_ESCAPES` (`define_method_sites.rb`, ADR 0288) | a `define_method` block body needs nothing of a frame it will not have | RETURN_BLK, BREAK, BLKPUSH, SUPER, ARGARY and definition ops refuse the site | those bodies | class-body `define_method(:x) { }` as a definition |
| `ClosedWorld#scan_factory` / `scan_singleton_maker` (`closed_world.rb`) | a `Struct`/`Class`/`Data` constant feeds exactly one `new`; no singleton is cut from a tracked object | the register that holds the factory is read only by a comparison or one `new` | any other use: `class_factory_escape` is a global refusal | closed-world soundness of the class tables |
| `FrozenTables` (`frozen_tables.rb`, ADR 0306) | avoids the question: a `.freeze` literal needs no alias analysis | frozen Array/Hash literals | mutable containers | element classes of tables |
| `block_blk_needs` / `needs_blk` (`codegen_block_fallback.rb`) | the enclosing method's block may be forwarded into a cfunc | BLKPUSH at level 1 only, callee on the allowlist | any other level or callee | `yield` inside a captured block |
| `BlockParamCall` (`codegen_block_param_call.rb`, ADR 0274) | `blk.call` where `blk` is the method's own, unrewritten `&blk` | reaching definition is the incoming slot | everything else | CORE_PROC_CALL arm |
| ADR 0308 `captured_local_class_enabled?`, ADR 0312 `ElementSiteReport` | no points-to: a local's class is the join of what is stored in that register; element classes of mutable containers were measured and not built | | | captured-local class flow; the 0.18 % ceiling |

Three things follow from the table. The by-name allowlist is the only proof that admits a block to a callee, and it
is stronger than a proof only in the sense that it cannot be wrong about a name the maintainers have not read: its
own comment lists the builds in which it is unsound (`flat_map`/`zip`/`with_index` if `mruby-enum-lazy` is
added, `step`, `new`, `upto`). The three register scans (`lambda_confined_call_sites`, `RecordHash`,
`ivar_assigned_before_exposure?`) each model the windows and writes of the same dozen ops differently. And
ADR 0312 closed with "the alias/escape machinery does not exist", which is true of containers and false of
registers.

## Decision

`tools/bc2cpp/escape_analysis.rb` is one module that answers one question for one creation site: **does the value
written by this instruction leave the frame that made it?** The default answer is "escapes"; a value is
non-escaping only when every instruction that can see it is on an audited list.

**The flow.** A forward may-alias set of registers over the irep's CFG, catch-handler edges included (a handler
sees the register as it was entered). Every op is classified: `KILLS_LEAD` (writes only its leading register),
`PASSES`, `STORES_LEAD` (SETIV, SETGV, SETCONST, SETUPVAR, RETURN, BREAK, RAISEIF, ASET: escape),
window ops (ARRAY, HASH, RANGE, CLASS, DEF: a value in the window is kept by the result), sends, closures. An op
the model does not name is an escape (`unmodelled_op`), as is a CFG with a jump to a non-instruction, a state
cap, and any `binding`/`eval`/`local_variable_*`/`ObjectSpace` anywhere in the world (`reflection`).

**The questions it answers**, per creation site (LAMBDA, BLOCK, ARRAY, HASH, STRING, the result of `new`):

1. *only registers or locals of the creating frame*: no reasons; `uses` lists the `.call`s made on it;
2. *passed as receiver, argument or block to a callee*: every definition the call can reach must have a
   **summary** saying that position is not kept. A summary is the same analysis run on the callee, started at its
   `self` (R0), its mandatory argument `k` (R1+k) or its block (the block parameter's local, every BLKPUSH, and the
   BLKPUSH of any closure nested in it). Native methods have no body; a native counts only through two audited
   tables: `NATIVE_BLOCK_NO_CAPTURE` (`section`, `select`, `count`, `index`, each with the files that register
   it, `NATIVE_MANIFEST`, checked against the sources) and `NATIVE_RECEIVER_OK` (`call`, `[]`, `size`, `<<` ...).
   mruby's iterators (`each`, `map`, `times`, `inject`) are Ruby in mrblib, so they need no table: their
   summaries come from bytecode. Recursion is co-inductive and never memoised on an assumption that the cycle's
   root does not itself keep;
3. *returned, stored (ivar, global, constant, upvar, array, hash, range, container), raised, read by a closure
   that escapes, handed to an unknown callee or a by-name send* (`send`, `public_send`, `method`,
   `instance_variable_set`, `to_proc`, `dup`, `Proc.new`/`proc`/`lambda` of a block, `define_method`,
   `Fiber.new`, `Fiber.yield`): escapes.

A closure made in the frame reads its locals (GETUPVAR), the method's block (BLKPUSH from a nested level) and,
for `self`, everything; it sees a tracked value safely only if neither it nor any closure between it and the
reading frame escapes, and the value does not escape in the reading frame.

**Callees are found by name over every definition**, so the answer holds for any receiver class: the registry as
`build_registry` leaves it **before** core filtering (a core method the build keeps interpreted is still a callee),
every `TDEF`/`SDEF`/`DEF`, literal `define_method`/`alias_method` (also through `send(:define_method, ...)`), and
`<scoped>` defs inside blocks (`Class.new { def ... }`). A name the world cannot enumerate has no callees at all:
an outside Ruby source this run does not compile defines it, a closed-world installer with unknown names can make
it, `method_missing` exists, or a computed `define_method`/`alias_method` makes the whole world dynamic.
**The analysis is not installed in an open world** (`closed_world` nil or `global_refusal`).

**Class-sharpened callee sets.** The name-level set is too coarse: `each` has 11 definitions, 5 of which keep their
block (`Enumerator#each` reaches the block through `__send__`). `World#defs_for` narrows a call to the method
resolution order of the receiver: the tracked value's own class (`Proc`, `Array`, ...), the compiler's class flow for
any other receiver (`exact_flow_mask`, which already requires singleton-free instances), and for an implicit self the
owner of the method **and its subclasses**. The tables for the classes the registry never declares are checked
against a real mruby in the check; a class neither declared nor tabled, a core class that C may have mixed into, an
unknown mixin, or an unplaceable class anywhere (for the subclass case) leaves every definition in the set.

**Consumer: BLOCK_FALLBACK_PROVEN.** `recognize_block_fallback_regions` admits a block that captures locals when the
callee is on `BLOCK_FALLBACK_UPVAR_SAFE_METHODS` **or** the analysis proves the block confined; the same fact
lets `needs_blk` forward the method's block. `BC2CPP_ESCAPE_ANALYSIS=0` removes the analysis and the output is
byte-identical to master.

Not built, with the numbers that decided it, below: typed-RProc direct calls beyond the one shape that exists,
compiling lambda-building core methods, replacing the allowlist, container element classes, stack allocation.

## Measurements

Wio closed world, master `43031b24`, `scripts/bc2cpp_coverage_report.rb` shipped pass with
`BC2CPP_ESCAPE_REPORT=<tsv>` (`tools/bc2cpp/escape_report.rb`, output byte-identical with it on) aggregated by
`scripts/bc2cpp_escape_report.rb`. "Sites" are creation instructions in every irep of the closed world (5,839 +
601 `new` sends); the second pass restricts them to methods that ship.

@@MEASUREMENTS@@

## Consequences

@@CONSEQUENCES@@
