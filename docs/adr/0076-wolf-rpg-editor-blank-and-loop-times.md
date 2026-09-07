# 76. WOLF RPG Editor Blank(0) and LoopTimes(179)

Date: 2026-09-07

## Status

Accepted

## Context

A full real-data command-code census of the sample game (every Common
Event and every map event, not just the ones already implemented) turned
up two commands whose real frequency far outweighs their implementation
cost, ahead of `Database`(250)'s own remaining surface, save/load
(220-222, only 13 real occurrences total), and transitions (160-162,
almost unused): `Blank`(0), WolfTL's own name, is the single most common
command code in the sample game (3468 real occurrences, always zero
args/strings) -- a deliberately empty command row the editor leaves
behind for a deleted command or a user adds purely for spacing, not
missing functionality. `LoopTimes`(179) ("回数付きループ",
help/04ev_control.html) is the fourth most common (438 occurrences): a
loop bounded to a real, possibly variable-held iteration count, sharing
`StartLoop`(170)'s own `LoopEnd`(498) terminator (WolfTL's Command.hpp
confirms there is only one `LoopEnd` code) rather than needing
`BreakLoop`(171) to exit.

The manual documents two behaviors this reader's existing loop machinery
(`StartLoop`/`BreakLoop`/`LoopEnd`/`GotoLoopStart`, from the "Event
movement" PR) did not need to care about, since `StartLoop`'s own
iteration state is stateless (it always jumps back until told to stop):
0 (or fewer) configured iterations mean the body never runs at all
("処理されないことを表すコメント色になります" -- the editor even
recolors it like a comment to show this); and `JumpLabel`(213) landing
*inside* a `LoopTimes` body from outside it runs the loop exactly once
regardless of the configured count, because "the remaining count" was
never established by that jump ("『外からループ内に入った場合』は回数は
反映されません"). The manual also documents that `GotoLoopStart`
("ループ開始へ", "return to the current loop's start point") ends the
current iteration early exactly the same way reaching `LoopEnd` does
(consuming one count), not skipping the count check the way jumping past
`LoopEnd` from outside the loop would.

## Decision

- `Wolf::Interpreter::Run#dispatch` gained `C_BLANK`(0) as a plain no-op,
  skipping `#unimplemented`'s own "not implemented yet" log entirely
  (it is not missing functionality).
- `C_LOOP_TIMES`(179)'s own remaining-iteration count lives in a new
  per-`Run` `@loop_counters` Hash, keyed by the `LoopTimes` command's own
  `@commands` index (not on `Command` itself, since the same physical
  line can be "active" with a different remaining count each time an
  outer loop wraps around and re-enters it) -- `#exec_loop_times`
  initializes it (or, for 0-or-fewer, `#skip_to`s straight past the
  loop's own `LoopEnd` without ever creating an entry); `#continue_loop`
  decrements it and either jumps back into the body or ends the loop.
- `#enclosing_loop_start_index` (`BreakLoop`/`GotoLoopStart`'s own
  bracket-matching scan) and the `LoopEnd`-position scan (renamed
  `#find_loop_start`, since it now only *finds* the opener -- deciding
  what to do next is `#continue_loop`'s job, shared with
  `GotoLoopStart`) now match `LoopTimes` alongside `StartLoop`.
- `#continue_loop(i, from_loop_end:)` takes an explicit flag rather than
  inferring it, because the "count exhausted" behavior differs by
  caller: `LoopEnd`'s own dispatch has *already* stepped past its own
  `LoopEnd` (nothing more to do -- `#skip_to`-ing again would consume the
  *next* `LoopEnd` in the command list instead); `GotoLoopStart` is
  still mid-body and must `#skip_to` the loop's own `LoopEnd` to end it
  early, exactly like `BreakLoop`. `(@loop_counters[i] || 1) - 1`
  implements the JumpLabel-from-outside gotcha directly: a loop entered
  without ever running `#exec_loop_times` has no entry, so it is treated
  as a fresh count of 1 and ends on the very first `LoopEnd`/
  `GotoLoopStart` it reaches.
- `BreakLoop`'s own dispatch now also clears `@loop_counters[i]` before
  its existing `#skip_to`, so a `LoopTimes` loop broken out of early
  starts fresh (rather than resuming a stale count) if an outer loop
  ever wraps around and re-enters the same line.

## Consequences

- `Blank`(0) no longer logs as unimplemented at all -- it was the
  loudest false "not implemented" signal in every soak-check run.
- `LoopTimes`(179) runs for real end to end: verified against four
  synthetic scenarios (a plain N-times repeat, 0 iterations, `BreakLoop`
  inside a `LoopTimes` loop, `GotoLoopStart` consuming an iteration) plus
  the JumpLabel-from-outside gotcha the manual documents, all matching
  the manual's own stated behavior exactly; the soak check and the
  compiled binary against the real sample game both exercise it with no
  new crash and no more "not implemented" log entries for either code.
- Still unimplemented, and lower-value by real frequency: save/load
  (220-222, 13 real occurrences -- and a real save-file *format*, not
  just command wiring, since 220/`SaveLoad`'s own Base operation
  serializes the whole game state, a much larger undertaking than
  220-222's occurrence count alone suggests), transitions (160-162,
  almost unused), `Effect`(290, 279 real occurrences, a large polymorphic
  screen-effect command in the same shape family as `Sound`/`Picture`),
  `Party`(270), `BanInput`(126), `ChangeColor`(151), `Checkpoint`(99),
  `WaitForMove`(202), `Teleport`(130), and `Database`(250)'s own
  remaining surface.
