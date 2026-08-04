- RPG Maker 2000: the **Control Variables** command now reads a **character's
  position** (operand type 6), previously unhandled (it silently returned the
  reference id). `param5` selects the character — `10001` the hero / party, a
  positive id a map event — and `param6` the value: 0 map id, 1 x tile, 2 y tile,
  3 facing (in the 2/4/6/8 numpad convention). The hero's values come from the
  running `Game::State`; an event's x / y / facing come from a new
  `Scene::Map#event_position` hook exposed through the interpreter's `map_info`.
  Matching a long-standing RPG_RT quirk, a **map event's map id reads 0**; screen
  coordinates (4 / 5) are not modelled and read 0, and an unresolvable reference
  (no map, unknown event) reads 0. So an event can now stash "where is the hero"
  or "where is event N" into a variable. Covered by new
  `scripts/rpg2k_logic_check.rb` checks (hero map id / x / y / facing; a map
  event's position with the map-id-0 quirk and an unknown-event fallback).
