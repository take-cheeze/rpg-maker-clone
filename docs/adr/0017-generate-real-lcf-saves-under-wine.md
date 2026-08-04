# 17. Generate real LCF saves under wine and validate a real RPG2003 save

Date: 2026-08-04

## Status

Accepted

## Context

ADR 0009-0014 built and validated the `LcfSaveData` schema
(`mruby-lcf/mrblib/schema.rb` `SAVE_DATA`) against a genuine RPG Maker **2000**
save -- one produced by playing Nepheshel to an in-game save point (a "Gate")
under EasyRPG Player and running `scripts/lcf_save_check.rb` over the result.
Synthetic blobs cannot catch a mistyped field, so validation has always insisted
on real editor/runtime output.

The gap was the **2003** edition. ADR 0013 validated real 2003 *database and map*
data (mtf-meido-action, Song-of-the-Sea decode as 2003, every `class_id`
resolves), but explicitly **deferred save-level 2003 validation**: the available
2003 games open with a *menu-disabled intro*, so the normal in-game Save cannot
be reached without playing through the scripted opening. Reaching Nepheshel's own
save point already needed a fragile playthrough; a save-disabled 2003 intro made
it impossible by the same route.

Two further frictions made even the 2000 case hard to reproduce in CI:

- Under a headless X server (Xvfb) with **no window manager**, wine never marks
  the SDL window as the foreground window, so EasyRPG receives no keystrokes --
  the game boots and renders but cannot be driven.
- EasyRPG's decision key is dropped when sent as a zero-length tap; it must be
  *held* (keydown, pause, keyup). Menu-cursor moves, conversely, want short taps
  so each advances exactly one cell.

## Decision

- **Use EasyRPG Player's test-play debug menu to save.** Launched with
  `--test-play`, EasyRPG binds **F9** to a debug menu whose first entry is
  **"Save"**. It invokes the normal save scene from anywhere, regardless of
  whether the game currently permits saving -- so it bypasses Nepheshel's Gate
  gating *and* the 2003 games' menu-disabled intro. Boot the game, start a New
  Game, then F9 -> Save -> a file slot writes a byte-real `Save<N>.lsd` with no
  playthrough, for either edition.
- **`scripts/gen-lcf-save-wine.bash`** encodes this headlessly: Xvfb +
  `matchbox-window-manager` (so the SDL window gets X input focus) + wine running
  `Player.exe --test-play`, driven with held decision keys / tapped cursor moves,
  then F9 -> Save -> slot, then `scripts/lcf_save_check.rb` over the output. It
  defaults to the **mtf-meido-action** RPG2003 test-bed (already in the download
  set, ships EasyRPG Player.exe) and takes any game dir + slot as arguments.

## Consequences

- **Save-level RPG2003 validation is now real, closing the ADR 0013 follow-up.**
  A genuine mtf-meido-action `Save01.lsd` parses cleanly through `SAVE_DATA` and
  round-trips into the runtime via `Game::State.from_lsd`
  (`scripts/rpg2k_save_load_check.rb`). The 2003 save exercises the same id-driven
  chunk layout as 2000 -- title, system, hero/vehicles, party actors (108),
  inventory (109), map events (111), foreground/common-event exec state
  (113/114) -- and the cross-checks hold: the `SAVE_TITLE` hero HP equals party
  actor 1's saved HP, and every `SAVE_MAP_EVENT` position matches a defined,
  in-bounds event on the current map. The pictures chunk (103) is heavily
  populated by the 2003 intro's CG, giving that section real bytes to read.
- **The undocumented top-level chunks 102, 112 and 200 appear in both editions'
  saves**, confirming they are written by the runtime independent of edition
  rather than being a 2000-only or 2003-only artifact. They remain undocumented
  (102 and 112 are one byte each, 200 is five) pending differential saves, as
  before.
- **Real-save fixtures are now reproducible without a manual playthrough**, for
  any RPG2000/2003 project EasyRPG can boot. That makes it cheap to regenerate a
  save after a schema change and to add new games as fixtures. The generated
  `.lsd` is not vendored (games are downloaded, not redistributed; `data/` is
  git-ignored) -- the script reproduces it on demand.
- The method depends on EasyRPG's `--test-play` debug menu and on a window
  manager being present under Xvfb; the script documents both. Games with a
  name-entry step before control (Nepheshel) need that one game-specific
  sub-sequence added before the F9 save; the 2003 test-bed reaches a saveable
  state with no game-specific steps.
