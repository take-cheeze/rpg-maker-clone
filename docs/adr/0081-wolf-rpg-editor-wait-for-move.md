# 81. WOLF RPG Editor WaitForMove(202)

Date: 2026-09-07

## Status

Accepted

## Context

`WaitForMove`(202), WolfTL's own name, is help/04ev_control.html's own
"→完了までウェイト": "現在処理されている「■動作指定」の処理が終わるま
で、次のコマンドを実行しません" -- does not execute the next command until
the currently-processing move route (`SetMoveRoute`(201)) finishes. The
wolfrpg-map-parser crate models it as a bare marker with no fields at all
(`EventControlCommand::WaitForMoveRoute`, parsed via its own generic
`parse_empty_command`), matching the sample game's own lone real call (0
arguments, 0 strings).

This reader's own `#run_route_commands` (the "Event movement" PR, ADR 0069)
already applies every `SetMoveRoute` step instantly -- "snap, no gradual
animation," the same simplification `Picture`(150)'s own Show/Move already
make -- so by the time control reaches *any* next command in the same
event, including a `WaitForMove` marker, the current event's own move
route has already fully finished. There is nothing left to wait for: this
is a genuine no-op in this reader's specific architecture, not missing
functionality, the same reasoning `Blank`(0)/`Checkpoint`(99) (ADR 0076/
0078) already established for a marker command with nothing left to do at
runtime.

## Decision

`Wolf::Interpreter::Run#dispatch` treats `C_WAIT_FOR_MOVE`(202) as a no-op,
alongside `Blank`(0)/`Checkpoint`(99).

## Consequences

- The sample game's own real call no longer logs as unimplemented;
  verified against the soak check, `ctest -R mruby_test` (crash count held
  at the pre-existing 19-crash baseline), and the compiled binary against
  the real sample game.
- If a future pass ever makes `SetMoveRoute` animate over multiple frames
  instead of applying instantly, this no-op would need to become a real
  wait; tracked here rather than silently left stale.
