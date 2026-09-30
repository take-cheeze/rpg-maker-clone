# 0280. bc2cpp drops the class test and the dynamic send of an arm whose receiver is provably exact

Date: 2026-09-30

## Status

Accepted

## Context

Three families of compile-time arms sit in front of a dynamic send and repeat a run-time class test:

- NATIVE_CORE_DIRECT (ADR 0257): `mrb_array_p(r) && ->c == M->array_class` before a verified core
  native (`Array#join`, `#shift`, `#compact`, `#index`, `String#bytes`), the send as its else;
- BLOCK_CORE_DIRECT (ADR 0270): one exact-class arm per Array, Hash, Range and Integer before the
  literal-block send of a compiled core method;
- NATIVE_DIRECT (ADR 0253): `mrb_obj_class(M, r) == rgss::native_<class>_class()` before an RGSS
  native entry point.

When the receiver is a value the compiler itself created (`[...]`, `{...}`, `a..b`, `"..."`, the
method's `*rest` array, `Klass.new`), the test can only be true, and the else is dead. The wio
closed-world build had 72 NATIVE_CORE_DIRECT, 344 BLOCK_CORE_DIRECT and 552 NATIVE_DIRECT sites, and
10954 cached dispatch sites.

Two things bound what can be removed:

- Only a proof that holds without a run-time check may replace the check. A `ClassLayout` ivar hint,
  a magic-comment annotation or a `known_class` reached across a branch join is a whole-program
  claim that every consumer re-checks (`trace_new_target(guarded: true)`); none of them is used.
- A block arm cannot lose its else. The entry of a compiled core block method sends a Fiber's frames
  to the bytecode with `bc2cpp_core_interpreted` (ADR 0269), which replaces the *cfunc frame that is
  running*. A compiled engine method has no such frame to give up, so the only way to reach that
  bytecode from a site is to dispatch, and dispatch needs the callinfo `mrb_funcall_with_block`
  pushes. A stub that raises would change what a game script sees inside a Fiber.

## Decision

**EXACT_CORE_RECEIVER** (`tools/bc2cpp/codegen_exact_receiver.rb`). At the final dynamic send of
`compile_send`, `exact_core_site` asks `exact_core_value_class` for the exact class of the receiver
register (and of the argument register, for `join`'s separator). It answers when
`irep.walk_dominating_writers` reaches, through MOVEs, one write that dominates the read:

- `ARRAY`/`ARRAY2` (Array), `HASH` (Hash), `RANGE_INC`/`RANGE_EXC` (Range), `STRING` (String), `LOADNIL`
  (NilClass, arguments only); `ARYPUSH`/`ARYCAT`/`HASHADD`/`HASHCAT`/`STRCAT` on the same register
  extend that value and are stepped over (`ARYSPLAT` is not: it calls `to_a`);
- method entry, for the `*rest` register (`rest_entry_class`, ADR 0270);
- or `compile_send`'s own `exact_new_receiver_class` proof of a fresh `Klass.new` of a stable class.

A loop, a branch join, a rescue or ensure path, an or-assignment and a write from a captured block all
fail dominance (`BytecodeIR.write_dominates?` accounts for upvar-written registers), so they are not
proven.

**Singleton-freedom.** "Created by the literal" means "exactly `Array`" only while nothing can give
the object a singleton class or a mixin. `ClosedWorld#exact_instances_singleton_free?` holds when the
closed world (mruby's own Ruby, which applies these only to Enumerator objects, aside) has no
`singleton_class`, `define_singleton_method`, `instance_eval` or `instance_exec` send or Symbol, no
`SDEF`/`SCLASS` whose target is not a class body's `self`, a constant no `SETCONST` assigns, or a fresh
`Object.new`, and no project native or outside Ruby file that makes a singleton class. `extend` is a
global refusal already (`:dynamic_mixin`). One violation anywhere withdraws every unguarded proof of
the build; the guarded arms are unaffected.

The site proof reaches the arm wrappers through `@exact_core_site`, which names the send it was made
for (register and name), so a nested compile cannot pick it up; it is part of
`METHOD_COMPILE_STATE`.

**What each family does with a proven receiver.**

- NATIVE_CORE_DIRECT: when the proven class owns the entry and its argument guard is proven too (none,
  or a String/nil separator for `join`), the site is `r = <verified body>;` with no test and no send
  (`NATIVE_CORE_EXACT`). Otherwise the arm keeps its argument guard and its send, and loses only the
  class test. These bodies are frame-independent (ADR 0257), so nothing is lost for a Fiber.
- NATIVE_DIRECT: a fresh RGSS `Klass.new` calls the entry point directly (`NATIVE_DIRECT_EXACT`); an
  integer argument that is not one still dispatches, so the binding raises its own TypeError.
- BLOCK_CORE_DIRECT: the arms shrink to the proven class and their class test goes
  (`if (M->c == M->root_c) { Klass_each_impl(...) } else { <the send> }`). The else stays, for the
  reason in Context.

**Not done: a receiver-sensitive core return-class table.** The idea was to let
`compute_class_return_names` accept audited native definitions so that `xs.map { }.join` or
`str.bytes.compact` has a traced receiver. Measured on the wio build, of the 158 `send_result`
receivers only 8 have a producer whose own receiver is exact (`(a..b).to_a.sort_by`, `x.map { }.any?`),
and every one of them feeds a block arm whose else stays; the `NATIVE_CORE_DIRECT` receivers behind a
`map { }` (`join` 10, `compact` 9) do not qualify because `Game::State#map` is an `attr_accessor`, so a
by-name proof for `map` disagrees, and the receiver of that `map` is not exact. A table would add code
and audit burden for no removed site, so it is left out until a consumer needs it.

## Consequences

- Wio closed-world report (`scripts/bc2cpp_coverage_report.rb`): cached dispatch sites 10954 to 10940.
  NATIVE_CORE_DIRECT 72 to 65 with 7 `NATIVE_CORE_EXACT` (`compact` 5, `join` 2); NATIVE_DIRECT
  552 to 546 with 6 `NATIVE_DIRECT_EXACT`; 13 BLOCK_CORE_DIRECT sites are narrowed to their proven class
  (`each` 6, `map` 3, `any?` 2, `flat_map`, `each_with_index`) and keep their else. Far fewer than the
  ~90 first estimated: most receivers of these arms are parameters, ivars, `GETIDX` results or
  `implicit self`, whose class only a guarded fact names.
- The unguarded proofs are a superset of nothing that existed before: no guarded arm changed.
- `scripts/bc2cpp_exact_receiver_check.rb` checks the generated code (every proof and every reason it
  is withheld, including each singleton-making construct, a Ruby override and the open world), then
  compiles a fixture with the compiled core into a full-core mruby and requires the interpreter's
  output for the same driver: literal, rest, alias and splat receivers, loop/branch/rescue/or-assign
  negatives, subclass and singleton receivers passed to the unproven paths, break/next/return/raise out
  of a proven block arm, GC pressure and calls from inside a Fiber.
- A world that defines a singleton on any non-class object, or calls `instance_eval`, loses all of
  this; the wio and desktop sources do neither.
- Residual risk: a native gem that creates a singleton class through a spelling the project-native
  regex (`NATIVE_SINGLETON`) does not know. The scan reads only the project's own native sources;
  mruby's core reaches the singleton makers only by the Ruby names refused above.
