- RPG Maker 2000: **random ("wandering monster") encounters** — until now the
  only way to start a fight was a scripted Enemy Encounter event command; the
  map tree's own encounter list (field 41 `enemy_groups`, field 44
  `encount_steps`, 25 by default) went unread. `Scene::Map#check_random_encounter`
  ports a reference implementation's own encounter-step handling (not
  independently confirmed against genuine RPG_RT under wine): every ordinary
  (non-forced) step adds the tile's terrain `encounter_rate` (database terrain
  field 3, 100 by default) to a running total, whose ratio to the map's step
  count is looked up in RPG_RT's own encounter table to scale that step's
  chance of a fight — a long walk with no encounter steadily grows more
  likely to end in one. A hit picks a uniform-random troop from the current
  map's own list, filtered by each troop's `terrain_set` (an omitted entry
  defaults to allowed), and opens the battle through a new
  `Game::Interpreter#start_random_battle` — the same request shape and
  `:battle` wait an Enemy Encounter command builds, just with no
  [Victory]/[Escape]/[Defeat] handler to route into. Escape is always allowed
  and a wipe is always game over, since a random encounter carries none of an
  Enemy Encounter command's own settings. First strike rolls RPG2000's own
  1-in-32 chance (the same reference implementation's chance roll, gated to
  the RPG2000 battle system; 2003's back-attack/pincer terrain rolls are a
  different battle system and do not apply here). Flying (the airship) is
  RPG_RT's one blanket exemption; a forced move route (a Move Event on the
  player, or Proceed With Movement) never rolls either, matching that same
  reference implementation's own gate on ordinary input-driven movement.
  `Change Encounter Rate` (11740) overrides the map's own step count, and the
  running total persists across a save (`Game::State#encounter_total`) the
  same way that reference implementation's own running total does — the
  encounter-table row it reads is deliberately not, matching its own unsaved
  index. Covered by new `scripts/rpg2k_scene_check.rb` checks (a guaranteed
  roll opening the right troop, an empty list never firing, `terrain_set`
  filtering, the airship exemption, a forced route never rolling, and the
  step-count lookup/override/default/disable cases).
