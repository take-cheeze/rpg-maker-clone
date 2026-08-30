- **Battle text moved on far faster than real RPG_RT.** The per-action banner
  ("Hero attacks! Slime takes 12 damage!") held for `BATTLE_ANIM_FRAMES`
  frames whenever the action had no battle animation to pace it instead
  (`Scene::Map#drive_battle_animate`, `mruby-rpg2k/mrblib/scene/map.rb`), and
  the encounter banner ("Slime appeared!") held for
  `BATTLE_ENCOUNTER_MSG_FRAMES`. Both were flat, arbitrarily short constants
  (20 and 4 frames) rather than derived from RPG_RT's own pacing. Ported
  from a reference implementation, not independently confirmed against
  genuine RPG_RT under wine: its own wait-scheduling
  shows it holds each message stage for its
  full `max_wait` unless the player actively holds Decision/Shift to skip
  ahead (its own wait-check decrements every
  frame regardless of input and only short-circuits early once a skip key is
  actually held) — tracing a plain attack that hits, with no animation, no
  crit and no state change through every stage that fires comes to 142
  frames (~2.4s) by default, and a bare encounter narration line holds for
  70 (`SetWait(30, 70)`). `BATTLE_ANIM_FRAMES` is now 90 (this banner shows
  the "attacks" and "damage" lines at once rather than as RPG_RT's two
  sequential pages, so it does not need the full 142 to be equally
  readable) and `BATTLE_ENCOUNTER_MSG_FRAMES` is now 70, both far closer to
  RPG_RT's own unskipped pace than the old values. `scripts/rpg2k_scene_check.rb`'s
  battle-phase-driving helpers and several individual checks had their own
  fixed frame budgets tuned to the old (much faster) pacing; these are
  widened to match.
