# 92. WOLF RPG Editor: BreakEvent(172)

Date: 2026-09-07

## Status

Accepted

## Context

`BreakEvent`(172) was grouped with four other low-frequency control
commands (`ForceStopMessage`(105), `ClearDebugText`(107),
`ReturnToTitle`(174), `EndGame`(175)) into a single "log and skip"
fallback, never individually counted. Re-running a full per-command-code
census against the sample game after `StringCondition`(112)'s own well ran
dry (this session's own established discipline: re-check rather than trust
the existing "suggested next order" list) found `BreakEvent`(172) alone
has 303 real calls -- by far the largest remaining unimplemented command
in the whole census, an order of magnitude more frequent than everything
else in that same fallback group combined (`ClearDebugText`(107) 1,
`ReturnToTitle`(174) 1, `EndGame`(175) 1, `ForceStopMessage`(105) 0).

The manual (`04ev_control.html`, "イベント処理中断") is unambiguous:
"以降のイベントコマンドを無視して、イベントを終了します" [ignores every
subsequent event command and ends the event]. Every one of the 303 real
calls is a bare `args=[], strings=[]` marker -- unlike `StringCondition`/
`BanInput`, there is no packed bit layout to get wrong at all, cross-
validated or otherwise (the crate does not model this command specifically
either, but there is nothing left for a struct to model).

## Decision

- `Run#dispatch`'s own `C_BREAK_EVENT` case sets `@index = @commands.size`
  directly, ending this Run's own `while @index < @commands.size` loop
  (`Run#execute`) on its very next check -- the same "this reader's own
  per-event command list is flat, indent is just markup" property
  `#exec_variable_condition`'s/`#select_branch`'s own marker-skipping
  already relies on, applied here to jump straight past everything
  remaining regardless of how many loop/branch levels deep the BreakEvent
  itself sits.
- Ends only the *current* Run, matching the manual's own plain "ends the
  event" (not "ends every event") wording: a blocking `CommonEvent`(210)
  call already drives its own callee `Run` to completion inside its own
  dispatch (`run.step while !run.done`) before the caller's own `Run`
  continues, so a `BreakEvent` inside a called Common Event naturally ends
  only that call, returning control to the caller exactly where the call
  itself was made -- no extra plumbing needed.
- `ForceStopMessage`(105)/`ClearDebugText`(107)/`ReturnToTitle`(174)/
  `EndGame`(175) stay in the same "log and skip" fallback they were already
  in -- each has 0-1 real calls in this sample game, an entirely different
  frequency tier from `BreakEvent`'s own 303.

## Consequences

- Verified by 2 new CRuby-level tests (a plain top-level stop, and a
  three-levels-deep StartLoop/VariableCondition/BreakEvent nesting proving
  the whole event ends rather than just the innermost construct), the
  CRuby harness (142 assertions, 0 failed), `ctest -R mruby_test` (crash
  count held at the pre-existing 19-crash baseline), the testbed and
  interpreter soak checks, and the compiled binary against the real sample
  game.
- This is a reminder that a command's real frequency can hide behind a
  shared "everything else" dispatch bucket -- worth re-scanning that
  bucket's own individual members, not just trusting its existence as a
  single already-triaged group, the next time the well looks dry.
