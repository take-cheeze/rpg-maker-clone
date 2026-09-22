# 0188. IvarLayout.trace_type skips genuinely read-only opcodes

Date: 2026-09-22

## Status

Accepted

## Context

`IvarLayout.trace_type`'s backward walk stops at the first instruction whose
disassembly prints the register being traced as its own first `R%d` token,
treating it as "some instruction we don't specifically model just wrote
`reg`" (the generic `else` branch's own documented, deliberately conservative
default). That default is sound but imprecise for eight real opcodes --
`RETURN`, `RETURN_BLK`, `BREAK`, `JMPIF`, `JMPNOT`, `JMPNIL`, `RAISEIF`,
`MATCHERR` -- which all print their lone register operand the same way
(`RETURN\tR%d\t`, `JMPNOT\tR%d\t%03d`, ...; confirmed against this repo's own
pinned `3rd/mruby` `include/mruby/ops.h` and `src/codedump.c`) but never
write to it: every one is a pure read (`return R[a]`, `if R[a] pc+=b`,
`raise(R[a]) if R[a]`, ...).

Found by hand-tracing a real, common idiom the diagnostic didn't explain:
`RPG2k::Window#pause=` (`v = v ? true : false; return v if v == @pause;
@pause = v; v`) compiles the early `return v if ...` guard to a `RETURN R1`
that sits, in bytecode program order, between the ternary's own
`LOADFALSE`/`MOVE` chain (which provably types `v` as `:bool`) and the
`SETIV @pause R1` that reads it. The backward walk hit that `RETURN` first,
matched it as "wrote R1", and stopped at `UNKNOWN` -- even though the
`RETURN` never executes on the path that actually reaches the `SETIV` (it is
a *later*, alternate exit sharing the same register slot after the method's
own local-variable count shrinks), and even were it always reached, it never
writes R1 either way.

## Decision

Add an explicit `when` arm for these eight opcodes that does nothing --
falls through to the next (older) instruction without ever treating the
matched register as written, the same "keep looking for whoever last really
wrote it" behavior a `MOVE` with a mismatched destination already gets.
Soundness is a direct reading of `ops.h`'s own semantics, not an inference
from any one call site: none of these eight ever assigns to the register
their own disassembly names, so skipping past one can never misattribute an
earlier, unrelated write to the same (reused) register number the way
skipping past an *actual* writer would.

`SETUPVAR` and `RESCUE` have the identical read-only-first-token shape
(checked against the same two files) but are deliberately left out:
`SETUPVAR`'s register interacts with the enclosing method's own upvar
bookkeeping this file already treats specially elsewhere
(`subtree_upvar_written_regs`), and `RESCUE` writes a *second* register
(`R[b] = R[a].isa?(R[b])`) this naive single-token regex can't even see --
both need their own, separately-verified follow-up.

## Consequences

A real, sound precision fix -- strictly fewer false `UNKNOWN`s, never a
wrong answer, verified with a standalone repro isolated from this file's own
registry noise (a `pure_mandatory_arity?` class with this exact
ternary-then-early-return shape: `@flag` now resolves `:bool`, `(none
embeddable)` before). It does **not** newly embed anything in the real
project or the standalone Optcarrot probe today: `scripts/
bc2cpp_coverage_report.rb`'s own `EMBED` count is unchanged in the real,
`drop_unsafe_embeddings`-filtered generated code (confirmed directly against
the regenerated `.cpp`'s own `_ivars` struct definitions, byte-identical
before and after), because `RPG2k::Window#@pause` -- the one real ivar this
change newly types -- still can't embed for a separate, well-documented, and
still-open reason: `RPG2k::Window#initialize(x = 0, y = 0, width = 0,
height = 0)` has four optional arguments, and `drop_unsafe_embeddings`
requires an embedding owner's own `#initialize` to be `pure_mandatory_arity?`
(the same gap `docs/adr/0139` repeats for many other classes, e.g.
`Game::Picture`). This fix will matter the moment that separate gap closes,
for `RPG2k::Window` and any future class with the same ternary-then-early-
return shape.

## Related: `RPG2k::Window` wired for registration completeness

Investigating this also found `RPG2k::Window`'s hand-written
`mruby-rpg2k-compiled/src/register.cxx` had drifted: its own `#dispose`
compiles clean (confirmed in the `== compiled entry points ==` diagnostic)
but was never installed, so it silently kept running the interpreted
`mrblib` body -- harmless today (no ivar of `RPG2k::Window` embeds, so
compiled and interpreted `#dispose` read/write the identical ordinary
`iv_tbl`), but exactly the class of drift `docs/adr/0144`'s own
`BC2CPP_WIRED_EMBEDDINGS`/`emit_owner_registrations` mechanism exists to
make impossible by construction. Adding `RPG2k::Window` to
`BC2CPP_WIRED_EMBEDDINGS` makes bc2cpp.rb's own generated
`bc2cpp_register_owner_methods` install every one of its 35 compiled entry
points unconditionally (verified: `scripts/bc2cpp_wired_embedding_check.rb`
now reports `RPG2k::Window: 35/35`) -- `#dispose` included -- with zero ivar-
embedding side effect (confirmed: the regenerated `.cpp` gains zero new
`_ivars` struct fields; `RPG2k::Window` is not `MRB_SET_INSTANCE_TT`, since
`embedding_classes` only ever names owners with a non-empty, `drop_unsafe_
embeddings`-surviving ivar set). A real, if modest, devirtualization win on
its own (one more real method -- called on every window destroyed/replaced,
message boxes and menu transitions alike -- now runs compiled instead of
interpreted), independent of the ivar-embedding gap above.

## A much larger, related gap found but not attempted here

Auditing every `mruby-rpg2k-compiled` owner's own registration the same way
`scripts/bc2cpp_wired_embedding_check.rb` already does for wired owners
(reusing its exact methodology, not a new one) found **402 of 2141**
compiled, `#error`-free entry points across the whole gem are never
installed by any mechanism -- neither the hand `register.cxx` nor
`emit_owner_registrations` (which only ever covers `BC2CPP_WIRED_EMBEDDINGS`'s
14 classes). These keep running the interpreted `mrblib` body today, real
`#error`-free C++ sitting entirely unused. The concentration is in the
hottest classes in the engine: `RPG2k::Scene::Map` (122 of 408 missing,
including `#update`, `#render`, `#draw_events`), `Game::Battle` (60 of 141,
including `#step`), `Game::Actor` (38 of 118), `Game::Party` (32 of 128) --
exactly the shape ADR 0186's own "Consequences" section already named for
`Game::Actor` specifically ("Making `Game::Actor` safe to embed needs that
separate registration gap closed too -- `emit_owner_registrations`-shaped
generation of every entry point, not this file's own scope").

Not attempted in this change: generalizing `emit_owner_registrations` to
cover every compiled owner (not just embedding ones) would flip several
hundred methods from interpreted to compiled at once across the game's own
hottest code paths, including the map and battle scene update loops. Every
one is independently proven `#error`-free by `compile_all`'s own
`SKIP_UNSUPPORTED` partition, the same bar this project already trusts for
2141 other entries -- but "compiles clean" is not "behaviorally identical to
the interpreter for every runtime value", and verifying that at this scale
needs the real desktop build (`RPGMAKER_BC2CPP=1`) actually run and played,
not just the CRuby-side checks this round could run. Left as a follow-up
with its own dedicated verification budget, per this project's own
established practice for a change of this size.
