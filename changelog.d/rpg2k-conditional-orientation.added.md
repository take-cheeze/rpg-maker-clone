- RPG Maker 2000: the **Conditional Branch** command now evaluates the
  **orientation** condition (type 6) — true when the referenced character is
  facing a given direction. `param1` is the character (`10001` the hero, a
  positive id a map event) and `param2` the direction (0 up / 1 right / 2 down /
  3 left, mapped to the runtime's 2/4/6/8 numpad facing). The hero's facing comes
  from `Game::State`; an event's from `Scene::Map#event_position` via the
  interpreter's `map_info`. An unresolvable reference (no map, unknown event, or
  the still-unmodelled this-event / vehicle refs) reads false. Previously this
  condition fell through to an unconditional "true". Covered by a new
  `scripts/rpg2k_logic_check.rb` check (the hero facing a direction takes the
  branch or the else, a map event's facing, and an unknown event falls to the
  else).
