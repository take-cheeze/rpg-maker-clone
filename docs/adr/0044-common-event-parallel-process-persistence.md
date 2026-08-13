# 44. Common Event Parallel Process interpreter continuation

Date: 2026-08-13

## Status

Accepted

## Context

`docs/TODO.md`'s "Common-event Parallel Process state should survive map
changes and saves, unlike a map event's" gap: within one map visit,
`Scene::Map#step_parallel` already resumes the same `Game::Interpreter`
instance across ticks, so a Common Event Parallel Process paused mid-script
(e.g. its gate switch turns off mid-run) genuinely freezes at that exact
command and resumes exactly there once ticking continues -- this part was
already correct. The two places that were not: `Scene::Map#perform_teleport`
and `Scene::Map#initialize` both call `#build_parallels` unconditionally,
which discards every parallel-process interpreter (map event and common
event alike) and rebuilds them from scratch. And `Game::State#to_h` /
`#to_lsd` have no field at all for a running interpreter's position, so even
if `build_parallels` were fixed, a save/load could not carry the position
across.

A Map Event's own parallel process is a different, already-correct story and
is not part of this gap: RPG_RT restarts it fresh on every page reselect
(`Scene::Map#new_parallel` / the "map event parallel process restarts via
`new_parallel` on every page reselect" fact already recorded in the TODO),
and this ADR does not touch that.

Two sub-problems, with different natural solutions:

- **Transfer Player (in-session).** `#perform_teleport` mutates `@map` /
  `@state` on the *same* `Scene::Map` instance -- it is not a fresh scene
  object. That means the live `Game::Interpreter` for a still-running Common
  Event parallel process (its call stack, its `waiting?`/`wait_kind` state,
  even `Scene::Map`'s own per-process `wait_timer` countdown for a Wait
  command in progress) is sitting right there in memory the whole time.
  Nothing about it needs serialising to survive a teleport -- `build_parallels`
  just has to stop throwing it away.
- **Save / load.** `RPG2k#continue_game` builds a brand-new `Scene::Map` from
  a loaded `Game::State`, with a brand-new `Game::Interpreter` for every
  parallel process. There is no live object to keep here; the position has to
  come from the state itself. But capturing genuinely arbitrary interpreter
  state (a nested Call Event's call stack, in-flight non-`:wait` UI requests,
  the `wait_timer` that lives on `Scene::Map`'s own parallel-process hash, not
  the interpreter) means designing and round-tripping a real continuation
  format through two different save encodings (the portable Marshal dump and
  the real `.lsd`). The `.lsd` side already carries a signal that this is
  larger than it looks: chunks 113 (foreground event) and 114 (common-event
  table) exist in `LCF::Schema::SAVE_DATA` and are known to hold exactly this
  kind of execution state (a real save taken from an on-screen choice keeps
  that choice's option strings inside chunk 113's blob), but their internal
  grammar is undocumented and left an opaque `int8_array` -- consistent with
  this codebase's rule that every schema field cites a source (a wiki page or
  a real-save decode), not a guess.

## Decision

- **Transfer Player: reuse the live interpreter, not a reconstruction.**
  `Scene::Map#build_parallels` now keys its previous `@parallels` entries by
  `common_event_id` before rebuilding, and for any common event id that
  already had a running parallel-process entry, pushes that *same* hash
  entry (interpreter, `wait_timer`, gate switch, everything) instead of
  calling `#new_parallel` again. Map event entries are always rebuilt fresh
  from the destination map's own event table -- unchanged, matching the
  existing per-visit-reset behaviour. This gives full fidelity (call stack,
  in-flight wait, everything) for free, because nothing is actually
  serialised: it is the same Ruby object before and after the teleport.
- **Save/load: a coarser, explicit checkpoint on `Game::State`.**
  `Game::Interpreter#resumable_index` returns the interpreter's current
  `@index` when it is safely capturable -- `@call_stack` empty (not paused
  inside a nested Call Event, whose frames nothing tracks how to
  re-resolve), and `@index` inside the list's bounds. It deliberately does
  *not* exclude `waiting?`: a blocking command always advances `@index` past
  itself before raising its wait, so the index is a valid resume point
  either way -- restoring it just means a resumed process skips replaying
  any remaining Wait duration rather than serving it again (the `wait_timer`
  countdown itself lives on `Scene::Map`'s side, not the interpreter, and is
  not part of this checkpoint). `Scene::Map#step_parallel` calls this after
  every tick of a common-event parallel process and writes it to the new
  `Game::State#common_event_progress` hash (id => index) -- but only when it
  returns non-nil, so a tick caught mid a nested call simply leaves the last
  known-good checkpoint in place rather than clearing it. `#common_event_progress`
  round-trips through `#to_h` / `.load` like any other save field.
  `Scene::Map#new_parallel` reads it back on the very first `#build_parallels`
  for a scene (a fresh game, or the `Scene::Map.new` that Continue builds) and
  calls the new `Game::Interpreter#start_at(commands, index)` -- `#start`
  followed by seeking to that index, or the top if the index is out of range
  (e.g. a stale save against edited event data).
- **`.lsd` chunks 113/114 are left opaque, as before.** No schema or writer
  changes there. Promoting them to a documented grammar needs a real save
  taken mid a Common Event Parallel Process to decode against, the same
  standard every other schema field in this codebase was held to (ADR
  0018-0020's chunk work, the existing `SAVE_FOREGROUND_EVENT` /
  `SAVE_COMMON_EVENT` opaque-blob comments) -- guessing a byte layout here
  would violate that standard rather than extend it. This means the `.lsd`
  export (`Game::State#to_lsd`) still does not carry a Common Event's
  parallel-process position; only the portable Marshal save does. Tracked as
  a named follow-up in `docs/TODO.md` rather than attempted here.

## Consequences

- **The primary reported gap is fixed for the common, in-session case with
  full fidelity**, and for the save/load case with a documented, narrower
  guarantee: a Common Event Parallel Process resumes exactly where it left
  off across a Transfer Player (its call stack and any in-flight wait
  countdown included, since the interpreter object itself is never rebuilt),
  and resumes at its last cleanly-observed command index across a genuine
  save/load (skipping past, not repeating, a Wait it happened to be mid-way
  through, and restarting a call stack it happened to be paused inside).
- **Map Event parallel processes are untouched.** They are never given a
  `common_event_id`, so neither the teleport-time reuse nor the save-file
  checkpoint ever applies to them; they keep restarting fresh on every page
  reselect, exactly as before.
- **Regression coverage** lives in `scripts/rpg2k_logic_check.rb` (the plain
  `Game::Interpreter#resumable_index` / `#start_at` contract, including the
  nested-call-stack and finished-process nil cases, and `Game::State
  #common_event_progress` round-tripping through `#to_h` / `.load`) and
  `scripts/rpg2k_scene_check.rb` (an end-to-end Transfer Player check proving
  both the command index *and* the `wait_timer` countdown survive untouched;
  an end-to-end save/load check built around the TODO's own example -- a
  gate switch turning off mid-run, then a Marshal round trip, then the switch
  turning back on; and a check pinning that a map event's own parallel
  process still gets a brand-new interpreter, and restarts at index 0, on
  every visit).
- **Follow-up work**, both already named in `docs/TODO.md`: decoding chunks
  113/114's real byte grammar against an actual save taken mid a Common Event
  Parallel Process (needed before the `.lsd` export can carry this state
  too); and, if it ever turns out to matter in practice, extending the
  save/load checkpoint to a position inside a Call Common Event chain (not
  attempted here since nothing currently records what a call-stack frame's
  target was, only its return `[list, index]` pair).
