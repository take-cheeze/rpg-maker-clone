- **RPG2003 battle:** A living but afflicted party member's own battle
  sprite (the alternate/gauge layout's per-actor battler graphic) now shows
  that status's own configured pose, matching real RPG_RT — Poison, Sleep,
  Confusion and every other active state used to leave the sprite
  indistinguishable from a perfectly healthy one; only Defend and Dead were
  ever shown. Falls back to a generic "bad status" pose when the state
  names none of its own. Covered by two new `scripts/rpg2k_scene_check.rb`
  checks.
