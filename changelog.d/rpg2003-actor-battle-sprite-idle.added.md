- **RPG2003's alternative/gauge battle layouts now draw each living party
  member as an Idle-pose sprite**, alongside the existing status window
  (which keeps showing HP/SP/party info exactly as before). Sourced from the
  database's Battler Animation table (`@db.battleranimations`, decoded in a
  prior change): the actor's resolved pose-set id (`Game::Actor
  #battler_animation_id`, mirroring a reference implementation's
  battle-animation-id fallback chain, not independently confirmed against
  genuine RPG_RT under wine — a runtime override from an actual
  Change Class event, else the current class's own default, else the
  actor's own database default) supplies the Idle pose (Pose id 0), whose
  `battler_name`/`battler_index` frame a `BattleCharSet/<name>` sheet in
  fixed 48x48 cells. Position is the actor's raw database `battle_x`/
  `battle_y` (chunk 11 fields 59/60), used literally.
  Scoped to the plain Idle pose only: no active state, not defending (pose
  transitions are follow-up work), and only the `animation_type == 0`
  (character/BattleCharSet) pose format — a pose using `animation_type == 1`
  (a full battle-animation/CBA sheet) or `battlecommands.placement ==
  automatic` (a grid-formula position this runtime does not compute) logs a
  `[RPG2k]` diagnostic and falls back instead of guessing, the same
  "reported gap, not silently invented" convention this codebase uses
  throughout. A traditional-layout (RPG2000) database draws no actor
  sprites, unchanged. Covered by new checks in `mruby-lcf/test/lcf_test.rb`,
  `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb`.
