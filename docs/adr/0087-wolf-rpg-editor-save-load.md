# 87. WOLF RPG Editor SaveLoad(220)

Date: 2026-09-07

## Status

Accepted

## Context

`SaveLoad`(220, "保存・読込") is the one WOLF command every prior pass this
session deferred as too large: help/04ev_file.html's own "[保存・読込
（セーブ/ロード）]" documents it as reading or writing the game's *entire*
running state, and ADR 0082 (`LoadVariable`(221)/`SaveVariable`(222))
explicitly scoped those two smaller commands around not needing that.
Revisiting it after `Effect`(290)'s own real-frequency well ran dry (ADR
0086's own Consequences) found the actual blocker smaller than assumed:

- **State capture**: `VarStore`'s own four flat banks (regular/system
  variables and strings) are already plain Hashes, and
  `Wolf::SaveData`(ADR 0082) already knows how to Marshal an arbitrary
  Ruby value to a project-relative file, including a Hash's own default
  value (verified directly against `3rd/mruby-marshal/src/marshal.cpp`'s
  own `ifnone` tag, not assumed from CRuby's own behavior alone).
- **Scene rebuild**: `Teleport`(130)'s own `pending_teleport` mechanism
  (ADR 0080) already does exactly the "resume at a different map/position,
  decided by a command, deferred to `WolfRPG#main_loop` once the current
  frame's `Interpreter#update` returns" dance this needs too.
- **"No event executing" after Load**: help/04ev_file.html's own "たとえ
  イベントの途中でセーブしていた場合でも、セーブデータをロードした直後
  は「イベントが実行されていない状態」から再開されます" turned out to be
  a near-trivial reset, not Fiber surgery: `Wolf::Interpreter#@common_
  runs`/`@map_runs` are plain Arrays of `{id/event_id:, run:, blocking:}`
  hashes, so dropping them outright orphans every `Run` currently sitting
  in either one -- nothing else ever holds a reference to step an
  orphaned `Run`'s own `Fiber` again, so it simply never executes another
  command, permanently, without needing to touch its own suspended state
  at all.

What real data (2 calls total, `CE#131`'s own "セーブ欄実行", `[0,
1600005]`/`[1, 1600005]`) does **not** need is this reader's *entire*
state: `1600005` is a common-event self-variable in the string quintet
(`vars.rb`'s own documented "common event self variables 5-9 ... are
string-only" range), so both real calls already route through the exact
"string-named save file" mode `SaveVariable`/`LoadVariable` proved out in
ADR 0082 -- no new save-path logic needed. This reader therefore keeps the
same *deliberately partial* posture ADR 0082 already established for 221/
222, one level up: `VarStore#snapshot`'s four banks plus the current map
id and hero position, explicitly **not** every self-variable bank (map or
common event), the database, or anything `Party`(270)-shaped -- all
already-documented "no foundation yet" gaps elsewhere in this reader, not
new ones introduced here. help/04ev_file.html's own wording ("データの一
部だけ操作することも可能です") and its own "特殊機能" section (already
conceding 221/222's own missing 可変DB data) both treat a legitimately
partial save as an ordinary, expected shape for this feature, not a
corner this reader is cutting alone.

## Decision

- `Wolf::Interpreter#exec_save_load` gates on the real 2-argument shape
  (`operation`, `save_number`) and reads/writes a new reserved key
  (`SAVE_LOAD_FULL_SAVE_KEY = :full_save`, a Symbol -- 221/222's own keys
  are always raw Integer value-ref ids, so the two can never collide) in
  the exact same file `Wolf::SaveData.path_for` already resolves for 221/
  222, so a project's save can freely mix full saves and individual
  variable writes the same way a real WOLF save does.
- **Save** (`operation` 0) snapshots `VarStore#snapshot`, `current_map_id`
  (a new `Interpreter` accessor -- `Wolf::Map` itself has no notion of its
  own id, so `WolfRPG#load_scene` now sets it alongside `current_map=`),
  and `current_scene.hero_pos`'s own x/y.
- **Load** (`operation` 1): a missing save or an unwritten key returns
  immediately (help/04ev_file.html's own documented "そのまま次のイベン
  トコマンドを実行します" falls out of doing nothing, the same as
  `LoadVariable`'s own missing-key default). A real snapshot restores
  `VarStore` (`#restore`, a new sibling to `#snapshot`), sets
  `pending_teleport` to rebuild the scene once this frame ends, drops
  `@common_runs`/`@map_runs` outright, and sets a new
  `#pending_run_reset` flag for the rest of the current frame only
  (`WolfRPG#main_loop` clears it again right after `Interpreter#update`
  returns). `Run#execute`'s own while-loop condition now also checks that
  flag, stopping the *one* `Run` still on the call stack -- the one whose
  own command this is -- from executing any more of its own commands;
  every other live `Run` needs no equivalent check, since dropping it from
  its own tracking array already means nothing will ever call `#step` on
  it again.

## Consequences

- Verified by four new CRuby-level tests (a real round trip through vars/
  map id/hero position via `Wolf::SaveData`, the documented missing-save
  no-op, the argument-count/unknown-operation gates, and a real
  `Interpreter#update`-driven integration test proving both halves of the
  abort behavior at once: an unrelated still-active Auto Common Event
  disappears from `#blocking?`, and the *same* Run's own command issued
  after the Load never executes), the CRuby harness (129 assertions, 0
  failed), `ctest -R mruby_test` (crash count held at the pre-existing
  19-crash baseline), the testbed and interpreter soak checks (`CE#131`
  itself is not reached by either bounded run -- like `CE#39`/`CE#94`
  before it, ADR 0086's own Consequences -- so the real string-named-save
  path was reviewed by hand, cross-checked against `SaveVariable`/
  `LoadVariable`'s own already-tested string-name handling rather than
  freshly exercised), and the compiled binary against the real sample
  game.
- A Run suspended mid-`Wait` (yielded inside `Fiber.yield`, not actively
  re-checking `execute`'s own while condition) when Load fires is dropped
  from its own tracking array just the same, so it is never stepped
  again -- but its own already-passed arguments (e.g. a partially-elapsed
  wait count) simply become moot rather than being explicitly unwound;
  there is no user-visible difference from "aborted", since nothing
  observes that state again either way.
- Still unimplemented: every self-variable bank, the database, and
  anything `Party`(270)-shaped, none of them captured by a Save or
  restored by a Load -- and `Interpreter#current_map`'s own pre-existing
  gap (nothing resets `@event_positions`, keyed by event id alone, on a
  map change) applies here exactly as it already does for `Teleport`(130)
  (ADR 0080's own "persistent per-map event state" TODO entry), not a new
  gap introduced by this pass.
