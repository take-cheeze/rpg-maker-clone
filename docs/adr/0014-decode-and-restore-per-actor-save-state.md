# 14. Decode per-actor save state and restore HP/MP on Continue

Date: 2026-08-03

## Status

Accepted

## Context

ADR 0011-0013 decoded the inventory and event-state save chunks and wired the
runtime's "Continue" (`Game::State.from_lsd`) to rebuild a state from a real
`Save<N>.lsd`. That restore covered the leader's position, the party roster,
gold, items, switches and variables, but the per-actor status chunk
(`SAVE_PARTY_ACTOR`, chunk 108) was modelled only as its opaque state block --
so a resumed party silently healed to full, dropping the saved vitals. The
runtime's `Actor` already models `hp`/`mp`/`level` and `Party#load_state`
already restores per-actor HP/MP (the portable Marshal save uses it), so the
gap was purely in decoding chunk 108 and feeding it through.

## Decision

- **`SAVE_PARTY_ACTOR`** now decodes the growth, vitals and equipment fields,
  decoded from a real save (Nepheshel Save01) and cross-checked against genuine
  data: `level` (31) and `exp` (32) -- level rises with exp across the roster
  (actor 3 is L5/307exp, actor 4 L8/1177exp); `skill_size`/`skills` (51/52, a
  `uint16[]` of the learned skills); current `hp`/`mp` (71/72); and `equipment`
  (61), five item ids `[weapon, shield, armour, helmet, accessory]`. Field 71 is
  confirmed by an independent chunk: the SAVE_TITLE summary's `hero_hp` (50 for
  the level-1 hero) equals actor 1's decoded HP. Equipment is confirmed against
  the database: every slot's id resolves to an item of the matching type (slot 0
  weapons, slot 2 armour, slot 3 helmets, slot 4 accessories; a dual-wield hero
  carries a second weapon in the shield slot). The base-stat block is present but
  left undecoded until proven. `hp`/`mp` carry no schema default, so an absent
  field reads as `nil` and never overwrites a live value.
- **`Game::State.from_lsd`** reads chunk 108, keys it by actor id, and passes the
  roster's saved current HP/SP into `Party#load_state`, so Continue resumes a
  wounded party instead of a fully-healed one.
- **`scripts/lcf_save_check.rb`** reports each saved actor's level/exp/HP/MP, and
  **`scripts/rpg2k_save_load_check.rb`** asserts every restored roster member's
  HP/MP matches its chunk-108 entry.

## Consequences

- Continue from a real save now preserves the party's vitals: the Nepheshel save
  resumes the hero at 50/0 HP/MP (its saved values) rather than full health, and
  the integration check enforces it. The save analyser surfaces the per-actor
  growth data that was previously invisible.
- Only current HP/MP are applied to the runtime; the runtime derives max HP/SP
  from the database at the actor's *initial* level and does not yet scale stats
  with level, so a high-level saved actor's HP can exceed the runtime's computed
  maximum. Level-scaled stats (and restoring level, exp, skills, equipment and
  states into the runtime, which has no equipment model yet) remain follow-up --
  the decoding added here is the prerequisite.
  No save fixture is bundled (games are downloaded, not redistributed), so the
  checks run against a locally generated save.
