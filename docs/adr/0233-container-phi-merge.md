# 0233. CONTAINER_PHI_MERGE: `x || []` receivers, and why the sound subset is empty

Date: 2026-09-25

## Status

Accepted

## Context

The block inliners (`codegen_loop_regions.rb` and friends) gate on the traced
receiver's class being exactly `Array`:

```ruby
return nil unless traced == 'Array'
```

so every remaining `BLOCK_FALLBACK` in the real hot-only RPG2k build is, in
effect, a receiver the tracer could not prove. One recurring shape among them is
`x || []` / `x && {}` -- `(@parallels || []).each`,
`(src[:pages] || []).each` -- which is a *phi* in the register: the branch
leaves `x` in the register on one arm and a container literal on the other, so
the register has two incoming definitions and a naive backward walk reads
whichever it hits first.

`JMPNOT`/`JMPIF` are in `READ_ONLY_OPCODE_SKIP` (ADR 0191), which is sound --
neither opcode assigns to the register its disassembly names -- but it means the
walk steps *past* the branch and the literal, to an older, unrelated write, or
off the top of the body to the argument register (which returns nil unless a
`ClassAnnotations` fact names it). The fix therefore has to be a real merge at
the branch, not a relaxation of the skip.

Before writing it, the shape was measured over the real closed world (all three
compiled gems, ~3,200 ireps, `mrbc -v` disassembly): there are **~200**
`JMPNOT`/`JMPIF` sites with a container literal on the fall-through arm. The
other (branch-taken) arm's writer, which is the side that has to agree, is:

| taken-side writer | sites |
| --- | --- |
| `GETIDX` | 88 |
| `MOVE` | 42 |
| `SEND0` | 37 |
| `GETIV` | 15 |
| `SEND` | 10 |
| `SSEND` | 4 |
| `SSEND0` | 3 |
| comparisons (`GE`/`GT`/`EQ`/`LE`) | 6 |
| `LOADNIL` | 1 |
| `KEY_P` | 1 |

Only `LOADNIL` (1 site) is a *definite* other class. `GETIV` is only as good as
the ivar's class fact, which is `UNKNOWN` for 547 ivars today. `SEND`/`SEND0`/
`SSEND`/`SSEND0` (54) are opaque returns. `GETIDX` (88) needs a resolved
`Array<Klass>`/`Hash<Klass>` element fact. `MOVE` copies are only meaningful
once the register they copy is itself resolved, which sends the question back
around.

## Decision

Add `container_phi_merge` (`tools/bc2cpp/dispatch_targets.rb`) and a
`JMPNOT`/`JMPIF` arm ahead of `READ_ONLY_OPCODE_SKIP` that consults it. The
helper merges a register's class across the branch **only** when the other arm
is provably the same container class, or provably nil:

* `LOADNIL` -- the arms are nil and the literal; nil is never a loop receiver.
* a literal of the *same* class -- both arms already agree.

Every other taken-side writer is refused, and the walk falls back to ADR 0191's
skip. The rule is deliberately one-sided: it can only *refuse*, never produce a
fact from a class it has not seen.

This is a stricter soundness bar than the rest of the typing work, and the
reason is specific. A `TYPED` send fact is checked at runtime
(`mrb_obj_class(M, recv) == owner_class_ptr`), so a wrong one costs a failed
compare and falls through to `mrb_funcall`. The block inliners do **not** check:
once `traced == 'Array'`, the emitted code indexes the register with
`RARRAY_LEN`/`RARRAY_PTR` and there is no fallback. A wrong merge would not
degrade, it would miscompile. So the merge must be right by construction, not
right by a guard.

## Consequences

Measured, not assumed. Building the real hot-only closed world with the phi
merge alone (the `ids_touch?` annotation stashed out, so the two are isolated):

```
diff of generated mruby-rpg2k-compiled.cpp: 0 lines
```

**Zero bytes, zero fallbacks, zero anything.** The sound subset is, on this
program, exactly the one `LOADNIL` site, and that site's receiver is not a
block receiver. `bc2cpp_hot_only_check` and `bc2cpp_nomethod_reviewed_check` pass
and `rpg2k_scene_check` is 1062/1062, i.e. the change is inert rather than
merely unhelpful.

Kept anyway, for two reasons. It is the first sound encoding of the phi shape,
so the unblocking work has somewhere to land. And it is cheap negative
inheritance: a future `-> Array` return annotation or `Hash<Klass>` element
fact promotes a `SEND`/`GETIV`/`GETIDX` taken-side writer into this helper's
admitted set, and those sites -- which are the overwhelming majority -- become
inlinable with no further change to this code.

The measurement is the actionable part: **the `||` sites are not blocked by phi
handling, they are blocked by the taken-side fact.** Of the remaining 17
non-rescue fallbacks, one (`Game::Transition#compute_block_order`'s three
`sort_by`s) additionally needs `Range#to_a` typing, and the rest need
recognizers that do not exist (`each_with_object`, arity-2 auto-splat, nested
block claims). Prioritising return-type annotations for container-returning
methods, and `Hash<Klass>` element annotations, is worth more than any further
branch analysis.
