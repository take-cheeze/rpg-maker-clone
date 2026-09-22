# 0192. trace_type/trace_new_target also skip SETUPVAR and RESCUE

Date: 2026-09-22

## Status

Accepted

## Context

`docs/adr/0188` and `docs/adr/0191` fixed `IvarLayout.trace_type` and the
shared `trace_new_target` helper (behind `ClassLayout`/`ArrayElementLayout`/
`HashElementLayout`) to skip past eight opcodes that print their lone operand
as the generic `R%d`-first-token shape but only ever *read* it (`RETURN`,
`RETURN_BLK`, `BREAK`, `JMPIF`, `JMPNOT`, `JMPNIL`, `RAISEIF`, `MATCHERR`).
Both fixes' own comments named two more candidates with the same
read-only-first-token shape, deliberately left out pending their own
verification: `SETUPVAR` (whose register "interacts with the enclosing
method's own upvar bookkeeping this file already treats specially elsewhere,
`subtree_upvar_written_regs`") and `RESCUE` (which "writes a SECOND register
... this naive single-token regex can't see").

Investigated both against this repo's pinned `3rd/mruby`
(`831da26b9021de0369d17b71b5667e2941a1a32d`) `include/mruby/ops.h` and
`src/codedump.c`, and against a real compiled repro, not guessed:

- **`SETUPVAR`**: `uvset(b,c,R[a])` (ops.h); `SETUPVAR\tR%d\t%d\t%d`
  (codedump.c) -- its only `R`-prefixed token is `a`, a same-frame, read-only
  source. `b`/`c` are plain decimal operands (an upvar slot and level,
  naming a register in an *ancestor* frame), never printed with an `R`
  prefix. The caution about `subtree_upvar_written_regs` turns out not to
  apply: that function walks a parent irep's *children* to collect
  `SETUPVAR`'s own `b` field (the slot index in the *parent's* register
  space) for a wholly separate mechanism (`FIXNUM_OPERAND_PROOF`). When
  `trace_type`/`trace_new_target` instead walk the *same* irep a `SETUPVAR`
  sits in, that instruction's only register token is its own frame's `a`,
  structurally disjoint from the `b` the other mechanism reads out of a
  different irep entirely. Confirmed against a real compiled closure
  (`f = lambda { x = y }`): from inside the block's own irep, `SETUPVAR R2 2
  0` only ever reads that block's own R2; the register it writes belongs to
  the enclosing method's irep, a file this trace never opens. Unconditionally
  safe to fold into the existing eight-opcode arm.
- **`RESCUE`**: `R[b] = R[a].isa?(R[b])` (ops.h); `RESCUE\tR%d\tR%d`
  (codedump.c) -- unlike every opcode in the existing arm, this one prints
  *two* `R%d` tokens, and the real write lands on the **second** (`b`), not
  the first every existing arm's naive single-token extraction assumes.
  `a` is read-only, exactly like the eight opcodes above; `b` is a genuine
  write and must stop the trace, not be skipped past. `trace_new_target`
  additionally hoists its register extraction *above* the `case` (`d =
  insn.args[/^R(\d+)/, 1]; next unless d == reg`, checking only the first
  token) -- which means a trace of `reg == b` through a `RESCUE` was already
  silently mishandled today, before this change: the hoisted filter would
  never even match it against the first token, discarding the instruction
  entirely rather than either skipping or correctly stopping. A pre-existing
  gap, not something this change introduces, but one this fix has to close
  at the same time to be sound.

A whole-program scan of every `SETIV`/`GETIDX`/`GETIDX0`-terminal register
history in the real closed world (3204 ireps, 114 `SETUPVAR` and 168
`RESCUE` instructions total, same `closed_world_mrblib_srcs` set `scripts/
bc2cpp_coverage_report.rb` feeds bc2cpp.rb) found **zero** sites where either
opcode currently sits between a real evidence-producing instruction and a
later terminal read of the same register -- the identical "sound but
currently zero-measurable-effect" outcome ADR 0188/0191 already accepted as
a legitimate reason to ship a precision fix.

## Decision

- Fold `SETUPVAR` into the existing nine-opcode... now ten... skip arm in
  both `IvarLayout.trace_type` and `trace_new_target`, unchanged in shape
  from the existing eight.
- Add a **separate, dedicated** arm for `RESCUE` in both functions, since it
  cannot share the existing blank arm's single-token assumption:
  - In `trace_type` (each `when` extracts its own registers): a `when
    'RESCUE'` arm that extracts both `a` and `b`, returns `UNKNOWN` if
    `b == reg` (a real write, stop here), and otherwise `next unless a ==
    reg` (skip past, keep searching).
  - In `trace_new_target` (register extraction hoisted above the `case`): an
    explicit `if insn.op == 'RESCUE'` check **before** that hoisted filter,
    since the filter itself would otherwise make `reg == b` unreachable.
    Extracts both registers, `return nil if b == reg` (stop, matching the
    function's own `UNKNOWN`-equivalent), otherwise skip past when either
    register matched (the loop's own `next unless d == reg` shape, just
    checking both tokens instead of one).

## Consequences

Two more real, sound precision fixes -- strictly fewer false `UNKNOWN`/
`OPAQUE` results, never a wrong answer -- shipped for the same reason
ADR 0188/0191 already were: closing a real analysis gap now, before some
future closed-world change (a new early-return sharing a register with a
`rescue`-typed check, or a closure capturing an outer local through the
exact register a later `SETIV` reads) silently reintroduces it. The
`RESCUE` fix additionally closes a real, if currently unexercised,
pre-existing correctness gap in `trace_new_target`'s hoisted-filter shape,
not just adds a new skip.

Verified to have **zero measurable effect** on the real project today, not
assumed: `scripts/bc2cpp_coverage_report.rb`'s full output is byte-identical
before and after (confirmed against the same baseline ADR 0191 already
established). All 22 `scripts/bc2cpp_*_check.rb` static checks pass.
