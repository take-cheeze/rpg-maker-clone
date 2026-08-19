- **A below/above-characters Player Touch or Event Touch event no longer
  blocks the party's own step.** `Scene::Map#step_movement` started the
  touched event's commands and unconditionally returned before ever setting
  `@moving`/`@dest_x`/`@dest_y`, so the party's step never completed even
  though `#passable?`/`#char_passable?` never treat a `LAYER_BELOW`/
  `LAYER_ABOVE` event as an obstacle anywhere else — matching real RPG_RT's
  `CheckEventTriggerHere` firing once the party has already arrived on the
  tile, not `CheckEventTriggerThere`'s bump-and-hold behaviour reserved for a
  genuinely blocking (`LAYER_SAME`) event. The common "invisible SE tile"
  pattern — a transparent below-characters event that plays a sound as the
  party crosses it, often gated on an item-possession/equip page condition —
  read as a solid wall instead. Covered by new `scripts/rpg2k_scene_check.rb`
  checks for both touch triggers on a below-characters event (the party still
  walks onto its tile) alongside the existing same-layer checks (still no
  move), updated to set `layer:` explicitly.
