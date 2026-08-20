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
shorts (maxHP, maxSP, atk, def, int, agi) *per level* -- but the schema's `status`
accessor, via its `order:` mapping, only ever surfaced the first (level-1) row.

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

✅ **Follow-up (2026-08-20): the curve layout itself was wrong.** This ADR's
own context section claimed chunk 31 is "six shorts (maxHP, maxSP, atk, def,
int, agi) *per level*" -- interleaved -- and `base_stats` indexed it that way
(`(level - 1) * 6 + stat_index`). That is not what liblcf writes. Its own
reader, `RawStruct<rpg::Parameters>::ReadLcf` (`src/ldb_parameters.cpp`),
reads six *separate*, same-length runs back to back -- every level's maxHP,
then every level's maxSP, then atk/def/int/agi -- and this project's `status`
cross-check (`curve[0..5]` equalling the schema's own level-1 `status` hash,
cited above as confirmation) never actually tested the layout: `status`'s
`order:` mapping decodes the identical first six raw shorts the same
stride-6 way, so the two agreed by construction, not by checking against an
independent source. Caught from a real player report of ally damage reading
roughly double real RPG_RT for the same fight, traced through a real
database (Nepheshel): the interleaved reading's level-1 ATK (59) was actually
the level-3 entry of the maxHP run. `base_stats` now reads `n = curve.size /
6` same-length blocks and indexes `curve[stat_index * n + (level - 1)]`,
matching the reference reader; the hand-built curve fixtures across
`rpg2k_logic_check.rb` (`CurveRow`/`ClassedRow`/`JobRow` growth tables) were
rewritten from interleaved rows to the same six-block layout via a shared
`block_curve` test helper. See `changelog.d/actor-growth-curve-block-layout.fixed.md`.
