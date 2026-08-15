- **Decoded RPG2003's Battler Animation table (database chunk 0x20)**, the
  named set of up to 12 poses (idle, attack, dead, defend, walk, victory, …) an
  actor's battle sprite can show. `@db.battleranimations` now reads back each
  entry's `speed` and its `poses` (id-keyed by the fixed Pose enum, one entry
  per pose) with `name`/`battler_name`/`battler_index`/`animation_type`/
  `battle_animation_id`; `player.battler_animation` and `job.battler_animation`
  are ids into this table. This corrects an earlier wiki-derived transcription
  (`battle_anime2`/`base_data`/`attack_motion`/`extension`) that had several
  field names and one default wrong, verified against liblcf's own chunk
  tables instead. This is foundational only — nothing reads the table or
  renders an actor sprite yet, so no game behavior changes. Covered by new
  checks in `mruby-lcf/test/lcf_test.rb`.
