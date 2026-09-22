# 0191. trace_new_target skips the same read-only opcodes as ADR 0188

Date: 2026-09-22

## Status

Accepted

## Context

`docs/adr/0188` fixed `IvarLayout.trace_type`'s backward register walk to skip
past eight opcodes (`RETURN`, `RETURN_BLK`, `BREAK`, `JMPIF`, `JMPNOT`,
`JMPNIL`, `RAISEIF`, `MATCHERR`) that print their lone operand as the generic
`R%d`-first-token shape the walk's own conservative `else` branch treats as
"some instruction we don't specifically model just wrote `reg`", but which in
fact only ever *read* that register (confirmed against this repo's own pinned
`3rd/mruby` `include/mruby/ops.h`/`src/codedump.c`, not guessed).

Investigating whether `ClassLayout.analyze`'s own backward trace -- which
proves an ivar/array-element/hash-value always holds an instance of a
specific class, the mechanism behind `CLASS_HINT`/`ELEM_HINT`/`HASH_ELEM_HINT`
-- has the identical gap found that `ClassLayout.analyze` does not walk
registers itself at all: it delegates to the shared top-level
`trace_new_target` (`tools/bc2cpp/bc2cpp.rb`), a function completely separate
from `IvarLayout.trace_type` that ADR 0188's fix never touched.
`trace_new_target` has the exact same vulnerable shape: a `(idx - 1)
.downto(0)` walk matching `d = insn.args[/^R(\d+)/, 1]` against the traced
register, dispatching on `case insn.op`, and falling through to a bare `else
return nil` for anything unmodeled -- with arms for `MOVE`, `GETIDX`/
`GETIDX0`, `SEND0`/`SEND`, `SENDB`, `GETIV`, `GETUPVAR`, `ARRAY`/`ARRAY2`,
`HASH`, `RANGE_INC`/`RANGE_EXC`, `GETMCNST`, `GETCONST`, but none of the eight
read-only opcodes ADR 0188 already vetted.

Verified empirically before fixing anything, the same "measured, not
assumed" discipline this whole ADR series holds itself to: compiled the
entire closed world with `mrbc -v` and scanned every `SETIV`/`GETIDX`-
terminal register history for the exact bug shape (one of the eight opcodes
sitting on the traced register between the `SETIV`/`GETIDX` and an earlier
real evidence-producing instruction). Across roughly 3,200 ireps and every
such site in the program, **exactly one** match exists program-wide --
`RPG2k::Window#pause=`'s `@pause = v` -- and that site is `IvarLayout`'s own
`:bool` proof (ADR 0188's fix already covers it), not a `ClassLayout` class
hint. Every plausible `CLASS_CANDIDATE_OPAQUE` in the real diagnostic
(`Game::Actor#@battle_commands`/`#@states`/`#@db_row`/`#@atb_gauge`,
`Game::Battle#@party`/`#@acting`, `Game::Interpreter#@face_owner`) was
checked by hand and is poisoned for an unrelated, legitimate reason (a
bool/nil-only write, an unannotated keyword argument, or a method name
`trace_new_target` never modeled as class evidence at all) -- none hits this
gap today.

## Decision

Add the identical `when` arm ADR 0188 added to `IvarLayout.trace_type`,
mirrored into `trace_new_target`: the same eight opcodes, same empty body
(falls through to the next older instruction without ever treating the
matched register as written), same soundness argument (a direct reading of
`ops.h`'s own semantics -- none of the eight ever assigns to the register its
own disassembly names, so skipping past one can never misattribute an
earlier, unrelated write to a reused register the way skipping past an
*actual* writer would).

Because `ArrayElementLayout`/`HashElementLayout` resolve their own
GETIDX-terminal element classes through this same shared `trace_new_target`
helper, the fix (and the "not currently exercised" empirical result) applies
to their class-resolution paths too, with no separate code change needed.

## Consequences

A real, sound precision fix -- strictly fewer false `OPAQUE` class hints,
never a wrong answer -- shipped for consistency with ADR 0188 and as
defense-in-depth against a future closed-world change (a new class, a new
early-return guard in an existing `#initialize`/accessor) silently
reintroducing the exact false negative ADR 0188 already fixed once, just on
`ClassLayout`'s side of the same shared helper instead of `IvarLayout`'s.

Verified to have **zero measurable effect** on the real project today, not
assumed: `scripts/bc2cpp_coverage_report.rb`'s full output (compiled entry
points, `CLASS_HINT`/`ELEM_HINT`/`HASH_ELEM_HINT` resolved/poisoned counts,
`EMBED`, dynamic-dispatch counts, everything) is byte-identical before and
after, confirmed with a `git stash`-bracketed A/B diff against the same
whole-program build. All 22 `scripts/bc2cpp_*_check.rb` static checks pass.
