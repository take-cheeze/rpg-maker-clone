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

**Per creation kind** (every irep of the closed world / methods that ship, "confined" = non-escaping by the
analysis, which needs a proof for every callee):

| Kind | Sites (all / shipped) | Confined (all / shipped) | Why the rest escape (top reasons, all) |
| --- | ---: | ---: | --- |
| `LAMBDA` | 31 / 3 | 1 / 1 | `stored_hash` 24 (the LCF schema DSL), `captured_by_escaping_closure` 3, `returned` 3 |
| `BLOCK` | 812 / 768 | 234 / 229 | `send_block` 578: a callee set that includes a definition that keeps the block |
| `ARRAY` | 1,621 / 903 | 47 / 46 | `stored_array` 631, `returned` 300, `send_receiver` 277 |
| `HASH` | 1,400 / 367 | 44 / 44 | `stored_hash` 962, `returned` 107, `stored_ivar` 89 |
| `STRING` | 1,975 / 1,508 | 790 / 772 | `send_argument` 604 (the rest are interpolation pieces that only reach `STRCAT`) |
| `Const.new` | 601 / 565 | 3 / 3 | `send_argument` 300, `stored_ivar` 121 |
| `initialize` (self) | 82 | 51 | 31 hand `self` to a callee that keeps it or return it |

**Lambdas.** 28 engine and 3 core `LAMBDA` ops, no `lambda {}`/`proc {}` forms. One is confined today
(`Menu#draw_status_row`, three `.call`s, three `CONFINED_LAMBDA_CALL`s in the output); two more compile with no
upvars. The analysis re-proves the one and finds **zero** newly confined lambdas and zero newly direct `.call`
sites: 24 are values stored into the LCF schema Hashes, `Symbol#to_proc`/`Hash#to_proc`/`Schema.lazy` return theirs,
and `Enumerable#inject`'s lambda is read by the closure it passes to `each`, whose callee set includes
`Enumerator#each`. Generalising CONFINED_LAMBDA_CALL to "a local passed to a non-capturing callee" is supported by
the module and by the fixtures (`c_lambda_arg`, `c_lambda_block_arg`) and was **not built**: nothing in this program has
that shape.

**Blocks.** 466 BLOCK_FALLBACK regions ship. The by-name allowlist admits all of them (the only ones declined by
name are in `Array#permutation`, `Array#combination`, `Enumerable#cycle` and `File.foreach`). The analysis proves
109 of the 466: the callees with one definition or a closed hierarchy (`times` 10, `page_field` 15, `section` 11,
`cached_bitmap` 8, `loop` 7, `each_index` 9, `index` 3, `reject!` 2 ...) and 38 of 206 `each` sends. The other
~357 are polymorphic by name: `each` has 11 definitions, 5 of which keep their block (`Struct#each` and
`Enumerator#each` through `__send__`, `Enumerator::Generator#each`, `Game::Actors#each`, `Game::Party#each`), and
only 70 of the 466 receivers have a class the class flow names (50 of them confined). **So the proof cannot replace
the allowlist**: doing it would remove compiled code today. It is a second way in, not a replacement.

**Dropping the ADR 0269 assumption by proof.** Of 126 core blocks, 4 shipped ones are proven confined; the core
iterators the assumption covers are `Enumerable` methods whose `each` is `self`'s, which the analysis cannot place
(`Enumerator` includes `Enumerable`). The run-time `bc2cpp_core_each_is_builtin` test stays.
**Compiling methods that build lambdas**: the three (`Enumerable#inject`, `Symbol#to_proc`, `Hash#to_proc`) escape
for the reasons above and stay bytecode. **Fiber-guard removal**: ADR 0314 (branch `bc2cpp-core-ruby-extend`) measures
the guard at about 7 by-name sends; the module would supply "does not escape", not "cannot reach Fiber.yield", and
YieldReach already supplies the latter. **Container element classes (ADR 0312)**: the ceiling there is ivar
containers, and every ivar-held container is a `stored_ivar` escape by definition; the module adds nothing until it
learns the writers of an ivar (ADR 0285's scan is the place). **Constructor pools**: the "self has not escaped"
rule of ADR 0261/0301 asks whether another method can *read the slot before it is assigned*, which a callee summary
("does not keep self") does not answer; the reusable part is the `[:self]` summary for `SSEND`s that the rule
currently treats as exposure (51 of 82 constructors keep `self`; how many of the 31 others are only exposure by a
plain `SSEND` is the number to measure with a "reads ivar X" summary). **Stack allocation**: 47 Arrays, 44 Hashes and
3 objects are used only locally (the 772 strings are interpolation pieces); a GC-visible stack object is not
something mruby has, so this is a count only.

**Built: BLOCK_FALLBACK_PROVEN.** Cutoff: at least 30 newly direct sites, or a clear unlock such as compiling a
refused core method. The numbers clear only the second, and only just: in the shipped wio output `Array#combination`
(`block.call` inside a recursive helper, previously `#error unhandled opcode BLOCK`) is the single method that
newly compiles, 380 lines of `shipped.cxx`. `Array#permutation` stays bytecode (its optional parameter keeps
`needs_blk` from being offered). `BC2CPP_ESCAPE_ANALYSIS=0` against master `56b14771`: `shipped.cxx` byte-identical.
`BC2CPP_ESCAPE_REPORT` on or off: byte-identical. Every other bc2cpp check that runs here gives the same result with
and without the switch (`closed_world`, `computed_send`, `unlisted_class_call`, `frozen_tables` fail identically on a
clean master in this environment); `bc2cpp_block_semantics_check` expected `t_yield_in_ensure` to stay interpreted
by name and now expects it compiled (its differential run against the interpreter passes).

## Consequences

**Removal versus relocation.** Nothing was removed. The private proofs stay as they are: the allowlist is stronger
than the analysis here, `lambda_confined_call_sites` is re-proved by it for the one site, and the three register
scans are not yet rebased. The migration plan, in order of payoff: (1) `RecordHash` ALIAS_SCAN and
`YieldReach#scan_keeps` onto `Analyzer#flow` (same question, different result type; each has a check to prove the
swap byte-identical); (2) `lambda_confined_call_sites` onto `creation(...).uses` plus
`BytecodeIR.reaching_definitions` for the must-alias of a direct call, which also admits the generalised shape;
(3) the allowlist shrinks to the names the analysis cannot prove only when receiver classes get sharper (the
`each` sends need `Struct`, `Enumerator`, `Generator`, `Actors` and `Party` excluded by the class flow).

**Next levers**, in order: a sharper receiver class for the 357 polymorphic block sends (ADR 0296 class pools:
ivar and argument pools, not this module), which turns the proof into the way the allowlist is audited; a "reads
ivar X" callee summary for the constructor-pool rule; the ivar writers for ADR 0312's containers.

**Soundness caveats, stated once.** (a) Computed-name sends are the closed world's own residual: `send(name, ...)`
with a name that is not a literal is not read as an installer, here as in `ClosedWorld`. (b) The class tables are a
claim about mruby 4.0's builtin classes, verified against a real mruby by the check. (c) The class flow's
exactness is `exact_instances_singleton_free?`. (d) Hostile `Marshal.load` data and native code that mutates frames
are outside the model, as for every proof here. (e) A native method is trusted only through a table that names the
source files; adding a native `each` (or a fifth block taker) fails the check until it is audited.

**Tests.** `scripts/bc2cpp_escape_analysis_check.rb`: hand-built bytecode for each escape route and the handler
and loop shapes; 19 confined and 41 escaping fixtures through mrbc; callee summaries; class sharpening; world facts;
the native manifest; generated code with 12 proven methods, 5 unproven, 12 withdrawal worlds (subclass override,
prepend, alias, define_method direct and through `send`, `method_missing`, an outside Ruby gem, a native, binding,
ObjectSpace, a computed define_method, open world) and the kill switch; then the compiled fixture against the
interpreter on full-core, core-only and 32-bit `mrb_int` builds (`BC2CPP_BLOCK_DIRECT_ENTRY=0` on the last: ADR 0271
keeps a block's entry as an address in a 32-bit slot, which this 64-bit host truncates), including GC stress,
`break`/`return`/`next`/`raise` through the callee, a stashed block called after its frame returned, lambda arity
strictness and a Fiber, and the compiled `Array#combination`. `scripts/bc2cpp_escape_analysis_mutation_check.rb`: an
unmutated control and 18 mutants inside the repository, all killed. CI shard `escape-analysis`.
