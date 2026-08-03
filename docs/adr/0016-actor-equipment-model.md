# 16. Actor equipment model with stat bonuses

Date: 2026-08-03

## Status

Accepted

## Context

ADR 0014 decoded the saved equipment (chunk 108 field 61: five item ids --
weapon, shield, armour, helmet, accessory) and ADR 0015 scaled base stats with
level, but the runtime had no equipment: New Game ignored an actor's initial
gear, Continue dropped the saved gear, and `Game::Actor#atk/def/int/agi` (read by
the Change Variable command's actor-stat operand) reflected only base stats.
Equipment bonuses in RPG2000 live on the item -- confirmed against real data,
every equipped weapon and piece of armour stores its bonus in the "points1" set
(atk/def/spi/agi) plus the max HP/SP points, whatever the slot (a dagger gives
+28 atk, cloth armour +7 def, scale mail +30 def / -5 agi).

## Decision

- **`Game::Actor` holds five equipment slots and folds their bonuses into the six
  effective stats.** Base stats (growth curve + Change Parameters) are kept
  separately; `atk`, `def`, `int`, `agi`, `max_hp` and `max_mp` now read
  base + the sum of the equipped items' bonus fields. `equip(ids)` swaps gear and
  `equipped?(item_id)` reports a slot match; changing level or a base parameter,
  or swapping equipment, recomputes the effective stats and re-clamps HP/MP.
- **New Game equips the actor's initial equipment** (database chunk 51) and
  **`Game::State.from_lsd` re-equips the saved gear** (chunk 108 field 61) before
  applying the saved HP/MP.
- **The actor "has item equipped" conditional branch** (type 5, sub-condition 5)
  is now modelled via `equipped?`.
- **`LCF::Array1D#respond_to_missing?`** (delegated by `LCF::File`) makes
  `respond_to?` reflect schema field names, so `Actor` can probe a database for
  an optional item table instead of rescuing a missing method.

## Consequences

- Equipment is live end to end: Nepheshel's hero starts New Game with its dagger
  and cloth armour (atk 59+28, def 64+7) and Continue restores the same gear;
  `rpg2k_save_load_check.rb` asserts the restored equipment, and the logic checks
  (83) cover the bonus maths, the base-vs-effective split under Change Parameters,
  and the equipped-item conditional. Scene checks (26) and the New Game path for
  unarmed/fixture actors are unaffected because an empty slot set adds nothing.
- Only the six flat stat bonuses are applied; equipment attributes/states,
  two-handed rules, equip-fix and cursed gear, and the max HP/SP "points2" set
  (unused by the sampled game) are not modelled yet -- follow-up. Bonuses are
  read straight from the database, so no fixture is bundled.
