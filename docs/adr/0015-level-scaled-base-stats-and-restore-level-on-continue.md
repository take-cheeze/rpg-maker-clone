# 15. Level-scaled base stats and restoring level/exp on Continue

Date: 2026-08-03

## Status

Accepted

## Context

ADR 0014 decoded the per-actor save chunk (level, exp, equipment, current HP/MP)
and restored current HP/MP on Continue, but flagged a gap: the runtime derived an
actor's max HP/SP (and the four battle stats) from the database at the actor's
*initial* level and never scaled them, so a resumed level-8 hero kept level-1
maxima and `from_lsd` restored current HP/MP against the wrong ceiling. The
database actually stores a full growth curve -- chunk 31 of each actor is six
shorts (maxHP, maxSP, atk, def, int, agi) ~~*per level*~~ -- but the schema's
`status` accessor, via its `order:` mapping, only ever surfaced the first
(level-1) row.

**Correction (2026-08-22):** the "six shorts per level" (row-major) layout
above was never verified against real RPG_RT and was wrong. The raw shorts
are actually stat-major -- six `max_level`-sized blocks, one per stat, not
`max_level` rows of six -- confirmed against a genuine `RPG_RT.exe`'s
displayed stats and fixed in `Game::Actor#base_stats`; see the dated
Follow-up on the Nepheshel-Equip-screen stat-mismatch entry in
`docs/TODO.md` for the full verification. This ADR's own decision below
(scaling stats by level via `int16_values(31)`) was and remains correct;
only the byte layout assumed while indexing into it was wrong.

## Decision

- **`LCF::Array1D#int16_values(idx)`** returns a chunk's raw little-endian short
  array, bypassing the `order:` mapping, so a caller can read the whole parameter
  curve rather than just its first row. `status` (the named level-1 view) is
  unchanged, keeping its schema and unit test intact.
- **`Game::Actor` scales its base stats with level.** `base_stats(level)` indexes
  the growth curve (via `int16_values(31)`) at the actor's level, clamped to the
  curve's length; `set_level(level)` recomputes the six stats and re-clamps
  current HP/MP to the new maxima. A row that only offers a `status` hash (the
  test fixtures, or a database without a curve) is treated as level-independent,
  so `Actor` works with both. New Game now also honours a non-1 initial level.
- **`Game::State.from_lsd`** restores each roster member's saved level (rescaling
  its stats) and exp before applying the saved current HP/MP, so Continue resumes
  a levelled, wounded party whose HP/MP sit within correctly-scaled maxima.

## Consequences

- Continue rebuilds actors at their real level: `rpg2k_save_load_check.rb` now
  asserts the restored level and exp and that each actor's current HP/MP stays
  within its rescaled maxima; the real Nepheshel save still round-trips (its
  level-1 leader is unchanged). The existing logic (81) and scene checks pass,
  and the New Game path is unaffected for level-1 actors because the curve's
  first row equals the old level-1 status.
- Only base stats scale; equipment bonuses, per-state modifiers and exp-driven
  level-up are still not modelled, and `exp` is stored but no gain-exp path
  consumes it yet -- follow-up. The growth curve is read straight from the
  database, so no save fixture is bundled.
