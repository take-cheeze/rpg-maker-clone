# 12. Resume the runtime from a real Save<N>.lsd

Date: 2026-08-03

## Status

Accepted

## Context

The RPG2000 runtime (`mruby-rpg2k`) only ever round-tripped its own portable
Marshal save (`saveN.mrb`); `main.rb` noted the LCF `.lsd` save schema "is not
modelled yet". ADR 0010 and 0011 validated and extended that schema against a
real `Save01.lsd`, so the runtime can now resume from genuine editor output --
the natural end-to-end check for the save loader (does a real save parse *and*
rebuild a usable game state, not just decode?).

## Decision

- **`Game::State.from_lsd(db, save)`** builds a runtime `State` from a parsed
  `LCF::SaveData` instead of our Marshal hash. It restores the fields the runtime
  models: the hero's map / tile position / facing (chunk 104), the party roster
  and its gold and items (inventory, chunk 109) and the switches and variables
  (system, chunk 101). Switches and variables are 0-indexed arrays in the save
  but 1-indexed in-game, so they shift by one; `save[101]` is used rather than
  `save.system` because that name collides with `Kernel#system` under the CRuby
  test harness.
- **`continue_game`** now loads the lowest-numbered existing `Save<N>.lsd`
  through `from_lsd` when one is present (so a real save dropped into the game
  directory resumes correctly), falling back to the Marshal save otherwise;
  `save_exists?` reports a `.lsd` too so the title's Continue is offered.
- **`scripts/rpg2k_save_load_check.rb`** is a CRuby integration check that loads
  a real `.lsd` plus the game's `RPG_RT.ldb` and asserts the reconstructed state
  (leader/position/facing, party, gold, items, switch and variable ids). It runs
  next to the other `rpg2k_*_check.rb` harnesses.

## Consequences

- Continue works from a genuine `Save01.lsd`: verified against the real Nepheshel
  save, which rebuilds as the leader on map 12 at (21,23) with 100G, two items
  and the saved switches/variables. The existing logic (57) and scene (17) checks
  still pass, so the Marshal path and `main.rb` wiring are unaffected.
- Only the modelled subset is restored. Per-actor HP/MP and the wider party
  roster (chunk 108 `SAVE_PARTY_ACTOR`), remembered vehicle positions and the
  event execution state (chunks 113/114) are not applied yet -- follow-up work,
  the same staged approach the runtime took for New Game. No `.lsd` fixture is
  bundled (games are downloaded, not redistributed), so the integration check,
  like `lcf_save_check.rb`, runs against a locally generated save.
