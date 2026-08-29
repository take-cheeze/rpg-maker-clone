# 45. Save/load file-select screen

Date: 2026-08-14

## Status

Accepted

## Context

`mruby-rpg2k` has supported multiple save slots at the storage layer since
ADR 0012 (`save_path(slot)` / `lsd_path(slot)`, `save_game(state, slot)`), but
nothing in the UI ever passed a slot other than the default: Scene::Menu's Save
command always wrote slot 1, and the title screen's Continue always read
whichever of slot 1's `.mrb` or *any* slot's `.lsd` happened to exist first
(`continue_game`'s old `existing_lsd` scanned 1..15 blind, since there was no
picker to ask the player which one they meant). `Game::State#to_lsd` already
writes the file-screen metadata a real save-select screen needs -- the SAVE_TITLE
chunk's timestamp, leader name/level/HP and up to four party FaceSets (see its
own doc comment) -- specifically so "a real RPG_RT file-select screen
shows the party"; nothing in this codebase read that data back out for the same
purpose. The database also already carries the vocabulary such a screen needs
(`term.save_file_select` / `load_file_select` / `file`, LCF::Schema term ids
146-148), unused until now.

## Decision

- **`RPG2k::MAX_SAVE_SLOTS`** (main.rb) replaces the `15` literal `existing_lsd`
  used to hardcode, shared by every slot-facing helper and by the new scene.
- **`RPG2k#load_save_state(slot)`** factors out "our own `.mrb`, else a genuine
  `Save<N>.lsd`, else empty" -- the lookup `continue_game` already did for
  slot 1, generalised to take a slot and used both by `continue_game` and by
  the new picker's slot previews. Errors are logged and swallowed (nil), since
  a preview should read as "empty" rather than crash the whole list over one
  unreadable file.
- **`RPG2k#save_exists?(slot)`** now checks that one slot only (previously it
  OR'd in "any `.lsd` exists anywhere", a stand-in for not having a picker to
  narrow it with). **`RPG2k#any_save_exists?`** is the new "is there anything
  to resume at all" check across every slot, and is what now gates the title
  screen's Continue entry.
- **`RPG2k::Scene::SaveLoad`** (new `mrblib/scene/save_load.rb`) is the
  file-select screen: a scrollable list of all `MAX_SAVE_SLOTS` slots, each
  showing the leader's name/level/HP, the party's gold and the current map
  (via `load_save_state`) or a "No Data" placeholder. It takes a `mode`
  (`:save` or `:load`):
  - Scene::Menu's Save command now pushes it in `:save` mode with the running
    `Game::State`; confirming a slot (occupied or not -- overwriting is
    allowed with no separate confirmation, matching RPG_RT) calls
    `RPG2k#save_game(state, slot)` and shows the same "Game saved."/"Save
    failed." feedback the menu used to show inline, then pops back once
    dismissed.
  - Scene::Title's Continue entry now pushes it in `:load` mode with `state`
    nil; only an occupied slot is selectable, and confirming one calls
    `RPG2k#continue_game(slot)`, which tears down the whole scene stack
    (picker included) and enters the map -- Continue's existing transition,
    now aimed at the chosen slot instead of a hardcoded one.
- **`continue_game`** takes an explicit `slot` (default 1, unchanged). The
  default now matters for exactly one caller: the `--rpg2k_continue` headless
  flag (Scene::Title's `auto_select?` path has no input loop to drive a second
  screen, so it keeps resuming slot 1 directly -- see
  `scripts/compare-nepheshel-wine.bash`, which watches stderr for the
  `[RPG2k-MAP]` marker only `continue_game` emits).
- **RPG2003's Open Save Menu (11910) and Open Load Menu (5001) event
  commands** (`Scene::Map#perform_event_save` / `#perform_event_load`) now
  open the same `Scene::SaveLoad` picker too, rather than acting on slot 1
  directly -- matching real RPG_RT, and reusing Open Main Menu's own
  push-then-wait-for-it-to-close shape (`Scene::Map#perform_event_menu`'s
  `@event_menu` flag) via a parallel `@event_save_load` flag: the first visit
  pushes the picker (in `:save` mode with the running state, or `:load` mode),
  the second -- once the picker has popped back off the stack -- resumes the
  interpreter. **Open Save Menu ignores `@state.save_access`** -- the very
  first version of this gated the picker behind it (matching Scene::Menu's own
  Save command), which turned out to be wrong: real testing against Nepheshel
  found its own Crystal Gate save-point event (map 12) sits on a map the tree
  flags Save-forbidden (`Game::MapAccess::TRISTATE_FORBID`), and the event
  still opens a save screen there in the genuine game -- "save only works at a
  gate" is exactly the design that relies on the event bypassing the general
  restriction, the same way `#perform_event_menu`'s Open Main Menu already
  ignores Change Main Menu Access (see its own doc comment). Fixed by dropping
  the `@state.save_access` branch from `#perform_event_save` entirely, so it
  now always pushes the picker; Scene::Menu's own Save command is unaffected
  and still checks it. Open Load Menu's cancel path is a genuine behaviour change:
  the old single-slot version unconditionally called `@interpreter.stop`
  (ending the triggering event outright, the same shape as Return to Title,
  since there was no cancel to distinguish from "no save data"), where a
  cancelled picker now `@interpreter.resume`s instead, letting the event
  continue past Open Load Menu the way RPG_RT does -- the "second visit"
  branch only runs after a cancel to begin with, since a *successful* load
  replaces the whole scene stack (this Scene::Map instance included) and so
  never reaches it. A parallel process (Common Event or map event) raising
  either wait is unaffected either way -- `step_parallel`'s
  `drive_parallel_wait` has no branch for `:save_menu`/`:load_menu`/`:menu`
  and silently resumes them all the same as before, a pre-existing gap this
  ADR does not close (Open Main Menu has always had it too).
- `scripts/rpg2k_scene_check.rb`'s `TitleParent` fixture gained
  `any_save_exists?`, `load_save_state` and `push`; its Continue checks now
  assert that the selection key opens `Scene::SaveLoad` in `:load` mode
  (available) or nothing at all (unavailable) rather than calling
  `continue_game` directly. `FakeParent` gained matching `pop`,
  `load_save_state`/`save_states`, `continue_game`/`continue_calls` and a
  slot-aware `save_game`. Seventeen new checks cover the picker itself (empty
  vs. occupied rows, confirm/cancel in both modes, scrolling/wraparound) and
  the two event commands driving it (push timing, a real save/continue through
  the pushed picker, `save_access` no longer blocking Open Save Menu, and Open
  Load Menu's cancel-resumes-the-event behaviour) -- including one built from
  Nepheshel's own Crystal Gate command shape (Show Choices -> a "SAVE" branch
  -> Open Save Menu), driven through a real choice confirm rather than calling
  `Game::Interpreter#choose` directly (which skips `Scene::Map#drive_message`'s
  `close_message` pairing and would have given a false pass against the
  pre-fix code).
- The Open Save Menu `save_access` fix was found and confirmed against real
  data: `scripts/native-build-without-nix.bash` built the native binary in
  this container (no Nix needed, per its own header), and a temporary debug
  hook in `start_new_game` reproduced Nepheshel's own Crystal Gate command
  list against the real database under `xvfb-run` -- the picker never opened,
  logging exactly the `[RPG2k] Open Save Menu: saving is disabled` line the
  pre-fix `#perform_event_save` printed, which traced straight to
  `Game::MapAccess.save_allowed?(12, ...)` reading that map's own
  `save == TRISTATE_FORBID` tree flag. The same run confirmed the fix: no more
  "saving is disabled" line, and the picker opens. The debug hook itself was
  never committed.

## Consequences

- The player can now save to, and resume from, any of the 15 slots through
  the menu and title screen alike, matching RPG_RT's own save/load screens
  (including their `term.save_file_select` / `load_file_select` / `file`
  vocabulary, when a database sets it).
- `save_exists?(slot)` no longer treats "any `.lsd` exists somewhere" as true
  for every slot; a project's own multiple manually-dropped `Save<N>.lsd`
  files now show up as their own distinct slots instead of collapsing onto
  whichever the old blind scan found first.
- Face thumbnails (which `to_lsd`'s title chunk exists specifically to
  support) are not drawn on the new screen yet -- it is text-only. Follow-up
  work, tracked in docs/TODO.md alongside routing the RPG2003 Open Save/Load
  Menu event commands through the same picker instead of slot 1 directly.
