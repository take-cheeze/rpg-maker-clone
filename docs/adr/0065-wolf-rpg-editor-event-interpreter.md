# 65. WOLF RPG Editor event-command interpreter

Date: 2026-09-06

## Status

Accepted

## Context

ADR 0064 gave WOLF RPG Editor projects a data layer and a passive,
walkable map view, but explicitly stopped short of running any events:
`Wolf::Command` decodes every event command a real project's Common Events
use, but nothing executed them. Since WOLF RPG Editor has no scripting
language and no built-in menu/title/save/battle system the way RPG2000 or
the RGSS makers do, the editor-bundled "RPG Basic System" *is* the game —
its Common Events implement the message window, the menu, save/load and
every other piece of what looks like built-in engine behaviour. Without an
interpreter, nothing beyond bare map geometry can ever appear.

No genuine `Game.exe`/wine harness exists for WOLF RPG Editor (unlike
RPG2000/XP, which get wine-diffed against real `RPG_RT.exe`/RGSS in this
repo), so command semantics here are reconstructed from three independent
secondary sources — WolfTL (C++), wolftrans (Ruby) and the
wolfrpg-map-parser Rust crate — cross-checked against each other and
against the one authoritative primary source available, the official
editor manual (`help/*.html`, from `smokingwolf/wolf_rpg_editor`'s GitHub
Pages source). Where sources disagree or a command's fixed-point/bitwise
semantics are not independently confirmed, the interpreter logs an
explicit "not implemented" warning and no-ops rather than guessing.

## Decision

Add `mruby-wolf/mrblib/vars.rb` and `mruby-wolf/mrblib/interpreter.rb`,
loaded (in that order, after `data.rb`) by the new `mrbgem.rake` dependency
on `mruby-fiber`:

- **`Wolf::ValueRef`/`Wolf::VarStore`** implement the editor's documented
  "変数呼び出し値" addressing scheme (`help/06valueget.html`): typing
  1,000,000 or more into any numeric field addresses a variable, switch,
  string, random range, system variable/string, a map or common event's own
  self-variable bank, or a database field, instead of a literal. `VarStore`
  is the single backing store every command reads/writes through, tracking
  which map/common event is "current" so "this event self" references
  resolve correctly both while a Run's own commands execute *and* while an
  auto/parallel Common Event's own run-condition is being checked (the
  condition fields can themselves be "this common event self" references).
- **`Wolf::Interpreter`**, with a nested `Run` class: one `Run` per live
  Common Event (or per call, for a non-reserved `CommonEvent` command),
  each backed by its own `Fiber` so a `Wait` command can suspend just that
  event without blocking the frame loop or any other event — the same
  per-run driver shape `mruby-rpgxp`'s `ScriptHost` uses for its own
  blocking main loop (ADR 0023), applied per running event here instead of
  once globally, since several Common Events (every parallel one, plus
  whatever they call) can be live at once. `Interpreter#update` advances
  every live auto/parallel run once a frame and starts newly-eligible ones;
  `WolfRPG#main_loop` (runtime.rb) calls it before the map scene updates.
- The command set implemented is the subset every source agrees on:
  `SetVariable`/`SetString` (a confidently cross-derived operator-word bit
  layout: an assignment nibble against a calculation nibble),
  `VariableCondition`'s multi-case branch structure (cross-confirmed
  byte-for-byte against the crate's own `CaseType` signatures),
  `StartLoop`/`BreakLoop`/`LoopEnd`, `GotoLoopStart` (WolfTL names it,
  confusingly, `StartLoop2`; the crate's own independent signature table
  names the same code `GotoLoopStart`, matching the manual's "ループ開始
  へ" menu entry — restart the loop immediately rather than exit it),
  `SetLabel`/`JumpLabel`, `Wait`, and `CommonEvent`/`CommonEventReserve`/
  `CommonEventByName` calls (including their numeric self-variable
  argument-passing and return-variable slot). Everything else (message
  boxes beyond a log line, choices, pictures, sound, teleport, `Comment`/
  `DebugMessage`, `StringCondition`'s string-vs-variable comparison
  encoding, `SetVariable`'s trig/random/bitwise operators, event/hero
  position get-or-set, database field writes) is an explicit, logged no-op.
- **`scripts/wolf_interpreter_check.rb`** soak-tests the interpreter the
  way `scripts/rpg2k_command_soak.rb` does for RPG2000: it drives every
  auto/parallel Common Event in the fetched sample game (225 Common
  Events, the entire "RPG Basic System") for 120 frames under a
  step-bounded `Run` subclass, asserting nothing raises and nothing hangs.
  This caught two real bugs no hand-built unit-test fixture exercised:
  `VariableCondition`'s no-match/no-`ElseCase` fallback scanned forward
  past its own `BranchEnd` hunting for an unrelated marker instead of
  stopping there, skipping a `Wait` the loop depended on to yield at all;
  and `GotoLoopStart` (176) was entirely unimplemented, so the one Common
  Event that uses it (`X[共]メッセージウィンドウ`, the message-display
  loop every other Common Event calls into) never returned to its loop's
  top. Both together produced a genuine, unbounded-CPU infinite loop
  against real game data — the soak check is what surfaced it, not the
  hand-built fixtures in `mruby-wolf/test/wolf_test.rb`.

## Consequences

- A WOLF RPG Editor project's own auto-start and parallel Common Events now
  run every frame, with real variable/switch/string state — the
  prerequisite for anything the RPG Basic System does (menus, saves,
  messages) to eventually work, even though the display side of most of
  that (real message windows, pictures, choices) is still unimplemented.
- Map events (their own trigger/movement/page-selection logic) still do not
  run; only Common Events do. That is `docs/TODO.md`'s next slice.
- The soak check (`scripts/wolf_interpreter_check.rb`) is the closest
  approximation to wine-diffing available for this maker and should be
  extended alongside every newly-implemented command, the same discipline
  `wolf_testbed_check.rb` already established for the data layer.
- `StringCondition`, position get/set variables, database field writes and
  `SetVariable`'s remaining operators are explicit follow-ups; adding each
  should extend both `mruby-wolf/test/wolf_test.rb`'s hand-built fixtures
  and be re-validated against the real sample game via the soak check.
